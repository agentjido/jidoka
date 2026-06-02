defmodule Jidoka.Workflow.Runtime.StepRunner do
  @moduledoc false

  alias Jidoka.Workflow.Runtime.Value
  alias Jidoka.Workflow.Step

  @spec run_step(Jidoka.Workflow.Spec.t(), Step.t(), map()) :: map()
  def run_step(_spec, %Step{}, %{error: error} = state) when not is_nil(error), do: state

  def run_step(spec, %Step{} = step, state) do
    case execute_step(step, state) do
      {:ok, result} ->
        put_in(state, [:steps, step.name], result)

      {:error, reason} ->
        Map.put(state, :error, step_error(spec, step, reason))
    end
  end

  @spec execute_step(Step.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute_step(%Step{kind: :function, target: {module, function, 2}} = step, state) do
    with {:ok, params} <- resolve_map(step.input, state, :function_input) do
      try do
        module
        |> apply(function, [params, state.context])
        |> normalize_function_result()
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end
  end

  def execute_step(%Step{kind: :action} = step, state) do
    with {:ok, params} <- resolve_map(step.input, state, :action_input),
         {:ok, tool} <- action_tool(step.target) do
      call_tool(tool, params, state.context)
    end
  end

  def execute_step(%Step{kind: :agent} = step, state) do
    with {:ok, prompt} <- Value.resolve(step.prompt, state),
         {:ok, prompt} <- ensure_prompt(prompt),
         {:ok, context} <- resolve_map(step.context, state, :agent_context),
         {:ok, result} <- call_agent(step.target, prompt, context, state.agent_opts) do
      {:ok, result.content}
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
end
