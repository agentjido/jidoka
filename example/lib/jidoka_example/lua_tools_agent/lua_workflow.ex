defmodule JidokaExample.LuaToolsAgent.LuaWorkflow do
  @moduledoc false

  require Runic
  import Runic, only: [context: 1]

  alias JidokaExample.LuaToolsAgent.CallTrace
  alias JidokaExample.LuaToolsAgent.LuaWorkflow.{Ref, Spec}
  alias JidokaExample.LuaToolsAgent.Policy
  alias Runic.Workflow

  @type t :: Spec.t()

  @spec run(map(), pid(), Policy.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(workflow_spec, trace, %Policy{} = policy, context) when is_map(workflow_spec) do
    with {:ok, spec} <- Spec.new(workflow_spec, policy),
         {:ok, state} <- execute(spec, trace, policy, workflow_context(context, trace)),
         {:ok, output} <- Ref.resolve(spec.output, state) do
      {:ok,
       %{
         "workflow_id" => spec.id,
         "output" => output,
         "steps" => state.steps
       }}
    end
  end

  def run(workflow_spec, _trace, %Policy{}, _context), do: {:error, {:invalid_lua_workflow, workflow_spec}}

  @doc false
  @spec run_step(map() | [map()], Spec.step(), pid(), Policy.t(), map()) :: map()
  def run_step(state, step, trace, %Policy{} = policy, context) do
    state
    |> merge_states()
    |> execute_step(step, trace, policy, context)
  end

  defp workflow_context(context, trace) when is_map(context), do: Map.put(context, :trace, trace)
  defp workflow_context(_context, trace), do: %{trace: trace}

  defp execute(%Spec{steps: steps} = spec, trace, %Policy{} = policy, context) do
    initial_state = %{steps: %{}, error: nil}

    workflow =
      steps
      |> Enum.reduce(Workflow.new(name: spec.id), fn step, workflow ->
        workflow_step =
          Runic.step(
            fn state ->
              __MODULE__.run_step(
                state,
                ^step,
                context(:trace),
                context(:policy),
                context(:context)
              )
            end,
            name: step.id
          )

        case step.after do
          [] -> Workflow.add(workflow, workflow_step)
          dependencies -> Workflow.add(workflow, workflow_step, to: dependencies)
        end
      end)

    workflow =
      Workflow.react_until_satisfied(workflow, initial_state,
        async: true,
        max_concurrency: policy.max_parallel_calls,
        deadline_ms: policy.timeout_ms,
        timeout: policy.timeout_ms,
        run_context: %{_global: %{trace: trace, policy: policy, context: context}}
      )

    final_state(workflow, steps, initial_state)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_step(%{error: error} = state, _step, _trace, _policy, _context) when not is_nil(error),
    do: state

  defp execute_step(state, step, trace, %Policy{} = policy, context) do
    with {:ok, arguments} <- Ref.resolve(step.arguments, state),
         {:ok, output} <- run_action_with_retries(step, arguments, trace, policy, context) do
      put_in(state, [:steps, step.id], output)
    else
      {:error, reason} ->
        %{state | error: {:lua_workflow_step_failed, step.id, reason}}
    end
  end

  defp final_state(%Workflow{} = workflow, steps, initial_state) do
    states =
      steps
      |> Enum.flat_map(fn step -> Workflow.raw_productions(workflow, step.id) end)
      |> Enum.filter(&match?(%{steps: _steps, error: _error}, &1))

    state = merge_states([initial_state | states])

    case state.error do
      nil -> {:ok, state}
      error -> {:error, error}
    end
  end

  defp merge_states(%{steps: _steps, error: _error} = state), do: state

  defp merge_states(states) when is_list(states) do
    states
    |> Enum.filter(&match?(%{steps: _steps, error: _error}, &1))
    |> case do
      [] ->
        %{steps: %{}, error: {:invalid_lua_workflow_state, states}}

      [state | states] ->
        Enum.reduce(states, state, fn state, acc ->
          %{
            acc
            | steps: Map.merge(acc.steps, state.steps),
              error: acc.error || state.error
          }
        end)
    end
  end

  defp merge_states(state), do: %{steps: %{}, error: {:invalid_lua_workflow_state, state}}

  defp run_action_with_retries(step, arguments, trace, %Policy{} = policy, context) do
    max_attempts = step.retries + 1
    do_run_action_with_retries(step, arguments, trace, policy, context, 1, max_attempts)
  end

  # Jido's action runtime may retry internally. This outer retry is the Lua workflow
  # retry budget and records one trace entry per workflow attempt.
  defp do_run_action_with_retries(step, arguments, trace, %Policy{} = policy, context, attempt, max_attempts) do
    with {:ok, call_id} <- CallTrace.reserve(trace, step.entry.id, arguments, policy.max_calls) do
      case run_action(step.entry.module, arguments, context) do
        {:ok, output} ->
          CallTrace.complete(trace, call_id, "ok", output)
          {:ok, output}

        {:error, reason} when attempt < max_attempts ->
          output = %{"error" => format_reason(reason), "attempt" => attempt}
          CallTrace.complete(trace, call_id, "error", output)
          do_run_action_with_retries(step, arguments, trace, policy, context, attempt + 1, max_attempts)

        {:error, reason} ->
          output = %{"error" => format_reason(reason), "attempt" => attempt}
          CallTrace.complete(trace, call_id, "error", output)
          {:error, output["error"]}
      end
    end
  end

  defp run_action(action, arguments, context) do
    context = Map.delete(context, :trace)
    tool = action.to_tool()

    case tool.function.(arguments, context) do
      {:ok, encoded} -> {:ok, decode_tool_payload(encoded)}
      {:error, encoded} -> {:error, decode_tool_payload(encoded)}
      other -> {:error, {:invalid_action_result, other}}
    end
  end

  defp decode_tool_payload(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> encoded
    end
  end

  defp decode_tool_payload(value), do: value

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
