defmodule Jidoka.Workflow.Runtime.StepRunner do
  @moduledoc false

  alias Jidoka.Workflow.Runtime.{Retry, Value}
  alias Jidoka.Workflow.Step

  @default_map_max_concurrency 8

  @spec run_step(Jidoka.Workflow.Spec.t(), Step.t(), map()) :: map()
  def run_step(_spec, %Step{}, %{error: error} = state) when not is_nil(error), do: state

  def run_step(spec, %Step{} = step, state) do
    state = ensure_runtime_state(state)

    with {:cont, state} <- maybe_run_step(step, state),
         {:ok, result} <- execute_step(step, state) do
      state
      |> put_in([:steps, step.name], result)
      |> put_in([:outcomes, step.name], %{status: :ok})
    else
      {:skip, state, reason} ->
        put_in(state, [:outcomes, step.name], %{status: :skipped, reason: reason})

      {:error, reason} ->
        state
        |> put_in([:outcomes, step.name], %{status: :error, reason: reason})
        |> Map.put(:error, step_error(spec, step, reason))
    end
  end

  @spec execute_step(Step.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_step(%Step{kind: :function, target: {module, function, 2}} = step, state) do
    with {:ok, params} <- resolve_map(step.input, state, :function_input) do
      Retry.call(step, fn ->
        module
        |> apply(function, [params, state.context])
        |> normalize_function_result()
      end)
    end
  end

  def execute_step(%Step{kind: :action} = step, state) do
    with {:ok, params} <- resolve_map(step.input, state, :action_input),
         {:ok, tool} <- action_tool(step.target) do
      Retry.call(step, fn -> call_tool(tool, params, state.context) end)
    end
  end

  def execute_step(%Step{kind: :agent} = step, state) do
    with {:ok, prompt} <- Value.resolve(step.prompt, state),
         {:ok, prompt} <- ensure_prompt(prompt),
         {:ok, context} <- resolve_map(step.context, state, :agent_context),
         {:ok, result} <-
           Retry.call(step, fn -> call_agent(step.target, prompt, context, state.agent_opts) end) do
      {:ok, result.content}
    end
  end

  def execute_step(%Step{kind: :gate} = step, state) do
    with {:ok, condition} <- Value.resolve(step.condition, state) do
      ensure_boolean(condition, :gate_condition)
    end
  end

  def execute_step(%Step{kind: :map} = step, state) do
    with {:ok, items} <- Value.resolve(step.over, state),
         {:ok, items} <- ensure_list(items, :map_over) do
      run_map_items(step, items, state)
    end
  end

  def execute_step(%Step{kind: :reduce, target: {module, function, 2}} = step, state) do
    with {:ok, items} <- Value.resolve(step.over, state),
         {:ok, items} <- ensure_list(items, :reduce_over),
         {:ok, params} <- resolve_map(step.input, Map.put(state, :items, items), :reduce_input) do
      Retry.call(step, fn ->
        module
        |> apply(function, [params, state.context])
        |> normalize_function_result()
      end)
    end
  end

  def execute_step(%Step{} = step, _state), do: {:error, {:unsupported_workflow_step, step.kind}}

  @spec step_error(Jidoka.Workflow.Spec.t(), Step.t(), term()) :: Exception.t()
  def step_error(spec, %Step{} = step, reason) do
    Jidoka.Error.execution_error("Workflow #{spec.id} step #{step.name} failed.",
      phase: :workflow_step,
      details: %{
        workflow_id: spec.id,
        step: step.name,
        kind: step.kind,
        target: step.target,
        reason: visible_reason(reason),
        cause: reason
      }
    )
  end

  defp resolve_map(value, state, field) do
    with {:ok, resolved} <- Value.resolve(value, state) do
      case resolved do
        %{} = map -> {:ok, map}
        other -> {:error, {:expected_map, field, other}}
      end
    end
  end

  defp maybe_run_step(%Step{} = step, state) do
    with {:ok, when_value} <- condition_allows?(step.condition_when, state, :when),
         :ok <- require_condition_value(when_value, true, :when),
         {:ok, unless_value} <- condition_allows?(step.condition_unless, state, :unless),
         :ok <- require_condition_value(unless_value, false, :unless) do
      {:cont, state}
    else
      {:skip, reason} -> {:skip, state, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp condition_allows?(nil, _state, :when), do: {:ok, true}
  defp condition_allows?(nil, _state, :unless), do: {:ok, false}

  defp condition_allows?(condition, state, kind) do
    with {:ok, value} <- Value.resolve(condition, state),
         {:ok, value} <- ensure_boolean(value, {:condition, kind}) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_condition_value(value, value, _kind), do: :ok
  defp require_condition_value(_value, _expected, kind), do: {:skip, {:condition_not_met, kind}}

  defp ensure_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp ensure_boolean(value, field), do: {:error, {:expected_boolean, field, value}}

  defp ensure_list(value, _field) when is_list(value), do: {:ok, value}
  defp ensure_list(value, field), do: {:error, {:expected_list, field, value}}

  defp run_map_items(%Step{} = step, items, state) do
    items
    |> Enum.with_index()
    |> Task.async_stream(
      fn {item, index} -> run_map_item(step, item, index, state) end,
      max_concurrency: map_max_concurrency(step, state),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, result}}, {:ok, acc} ->
        {:cont, {:ok, [result | acc]}}

      {:ok, {:error, {index, reason}}}, {:ok, _acc} ->
        {:halt, {:error, {:map_item_failed, index, reason}}}

      {:exit, reason}, {:ok, _acc} ->
        {:halt, {:error, {:map_item_failed, :exit, reason}}}
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_map_item(%Step{} = step, item, index, state) do
    item_state =
      state
      |> Map.put(:item, item)
      |> Map.put(:index, index)

    with {:ok, params} <- resolve_map(step.input, item_state, :map_input),
         {:ok, result} <- execute_map_target(step, params, state.context) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {index, reason}}
    end
  end

  defp execute_map_target(%Step{target_kind: :function, target: {module, function, 2}} = step, params, context) do
    Retry.call(step, fn ->
      module
      |> apply(function, [params, context])
      |> normalize_function_result()
    end)
  end

  defp execute_map_target(%Step{target_kind: :action} = step, params, context) do
    with {:ok, tool} <- action_tool(step.target) do
      Retry.call(step, fn -> call_tool(tool, params, context) end)
    end
  end

  defp execute_map_target(%Step{} = step, _params, _context), do: {:error, {:unsupported_map_target, step.target_kind}}

  defp map_max_concurrency(%Step{max_concurrency: step_max}, state) do
    case Enum.reject([step_max, Map.get(state, :max_concurrency)], &is_nil/1) do
      [] -> @default_map_max_concurrency
      caps -> Enum.min(caps)
    end
  end

  defp normalize_function_result({:ok, result}), do: {:ok, result}
  defp normalize_function_result({:error, reason}), do: {:error, reason}
  defp normalize_function_result(result), do: {:ok, result}

  defp action_tool(action) when is_atom(action) do
    if Code.ensure_loaded?(action) and function_exported?(action, :to_tool, 0) do
      {:ok, action.to_tool()}
    else
      {:error, {:invalid_action_module, action}}
    end
  end

  defp action_tool(action), do: {:error, {:invalid_action_module, action}}

  defp call_tool(%{function: function}, arguments, context) when is_function(function, 2) do
    case function.(arguments, context) do
      {:ok, encoded} -> {:ok, decode_tool_payload(encoded)}
      {:error, encoded} -> {:error, decode_tool_payload(encoded)}
      other -> {:error, {:invalid_action_result, other}}
    end
  end

  defp call_tool(_tool, _arguments, _context), do: {:error, :invalid_action_tool}

  defp decode_tool_payload(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> encoded
    end
  end

  defp decode_tool_payload(value), do: value

  defp ensure_prompt(prompt) when is_binary(prompt), do: {:ok, prompt}
  defp ensure_prompt(prompt), do: {:error, {:expected_prompt, prompt}}

  defp call_agent(agent, prompt, context, agent_opts) when is_atom(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :run_turn, 2) do
      opts =
        agent_opts
        |> Keyword.put(:context, context)

      case agent.run_turn(prompt, opts) do
        {:ok, result} -> {:ok, result}
        {:hibernate, snapshot} -> {:error, {:agent_hibernated, snapshot}}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_agent_result, other}}
      end
    else
      {:error, {:invalid_agent_module, agent}}
    end
  end

  defp call_agent(agent, _prompt, _context, _agent_opts), do: {:error, {:invalid_agent_module, agent}}

  defp visible_reason(%{message: message}) when is_binary(message), do: message
  defp visible_reason(reason), do: reason

  defp ensure_runtime_state(state) do
    state
    |> Map.put_new(:outcomes, %{})
    |> Map.put_new(:max_concurrency, nil)
  end
end
