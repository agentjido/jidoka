defmodule Jidoka.Workflow.Lua.Plan do
  @moduledoc false

  require Runic
  import Runic, only: [context: 1]

  alias Jidoka.Workflow.Lua.CallTrace
  alias Jidoka.Workflow.Lua.Plan.{Ref, Spec}
  alias Jidoka.Workflow.Lua.Policy
  alias Jidoka.Context
  alias Runic.Workflow

  @type t :: Spec.t()

  @spec run(map(), pid(), Policy.t(), Context.t() | map()) :: {:ok, map()} | {:error, term()}
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
  @spec run_step(map() | [map()], Spec.step(), pid(), Policy.t(), Context.t()) :: map()
  def run_step(state, step, trace, %Policy{} = policy, context) do
    state
    |> merge_states()
    |> execute_step(step, trace, policy, context)
  end

  defp workflow_context(%Context{} = context, _trace), do: context
  defp workflow_context(context, _trace), do: Context.from_data!(context)

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
    with {:ok, true} <- step_condition_passed?(step, state),
         {:ok, output} <- execute_step_kind(state, step, trace, policy, context) do
      put_in(state, [:steps, step.id], output)
    else
      {:ok, false} ->
        put_in(state, [:steps, step.id], skipped_output())

      {:error, reason} ->
        %{state | error: {:lua_workflow_step_failed, step.id, reason}}
    end
  end

  defp step_condition_passed?(%{condition: nil}, _state), do: {:ok, true}

  defp step_condition_passed?(%{condition: condition}, state) do
    with {:ok, value} <- Ref.resolve(condition, state) do
      {:ok, truthy?(value)}
    end
  end

  defp execute_step_kind(state, %{kind: :action} = step, trace, %Policy{} = policy, context) do
    with {:ok, arguments} <- Ref.resolve(step.arguments, state) do
      run_action_with_retries(step, arguments, trace, policy, context)
    end
  end

  defp execute_step_kind(state, %{kind: :map, map: map} = step, trace, %Policy{} = policy, context) do
    with {:ok, source_items} <- Ref.resolve(map.over, state),
         {:ok, source_items} <- ensure_list(source_items, :map_over),
         {:ok, calls} <- map_calls(step, source_items, state),
         {:ok, items} <- execute_map_calls(calls, trace, policy, context, map.max_concurrency) do
      {:ok,
       %{
         "items" => items,
         "count" => length(items),
         "source_count" => length(source_items),
         "truncated" => length(source_items) > length(calls)
       }}
    end
  end

  defp execute_step_kind(state, %{kind: :reduce, reduce: reduce}, _trace, _policy, _context) do
    with {:ok, values} <- Ref.resolve(reduce.over, state),
         {:ok, values} <- ensure_list(values, :reduce_over) do
      reduce_values(values, reduce)
    end
  end

  defp execute_step_kind(state, %{kind: :gate, gate: gate}, _trace, _policy, _context) do
    with {:ok, left} <- Ref.resolve(gate.left, state),
         {:ok, right} <- Ref.resolve(gate.right, state),
         {:ok, passed} <- evaluate_gate(gate.op, left, right) do
      {:ok,
       %{
         "passed" => passed,
         "op" => gate.op,
         "left" => left,
         "right" => right
       }}
    end
  end

  defp execute_step_kind(_state, step, _trace, _policy, _context), do: {:error, {:unsupported_lua_workflow_step, step}}

  defp skipped_output, do: %{"status" => "skipped", "reason" => "condition_false"}

  defp map_calls(%{map: map}, source_items, state) do
    source_items
    |> Enum.take(map.max_items)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, calls} ->
      vars = %{map.as => item}

      case Ref.resolve(map.arguments, state, vars) do
        {:ok, arguments} when is_map(arguments) ->
          call = %{
            id: "map_item_#{index}",
            entry: map.entry,
            arguments: arguments,
            retries: map.retries
          }

          {:cont, {:ok, calls ++ [call]}}

        {:ok, arguments} ->
          {:halt, {:error, {:invalid_lua_workflow_map_arguments, arguments}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_map_calls([], _trace, _policy, _context, _max_concurrency), do: {:ok, []}

  defp execute_map_calls(calls, trace, %Policy{} = policy, context, max_concurrency) do
    workflow =
      calls
      |> Enum.reduce(Workflow.new(name: :lua_workflow_map), fn call, workflow ->
        workflow_step =
          Runic.step(
            fn _state ->
              __MODULE__.run_map_item(
                ^call,
                context(:trace),
                context(:policy),
                context(:context)
              )
            end,
            name: call.id
          )

        Workflow.add(workflow, workflow_step)
      end)

    workflow =
      Workflow.react_until_satisfied(workflow, %{},
        async: true,
        max_concurrency: min(max_concurrency, policy.max_parallel_calls),
        deadline_ms: policy.timeout_ms,
        timeout: policy.timeout_ms,
        run_context: %{_global: %{trace: trace, policy: policy, context: context}}
      )

    collect_map_results(workflow, calls)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec run_map_item(map(), pid(), Policy.t(), map()) :: {:ok, term()} | {:error, term()}
  def run_map_item(call, trace, %Policy{} = policy, context) do
    run_action_with_retries(call, call.arguments, trace, policy, context)
  end

  defp collect_map_results(%Workflow{} = workflow, calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, results} ->
      case workflow |> Workflow.raw_productions(call.id) |> List.last() do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:error, reason} -> {:halt, {:error, {:lua_workflow_map_item_failed, call.id, reason}}}
        other -> {:halt, {:error, {:missing_lua_workflow_map_result, call.id, other}}}
      end
    end)
  end

  defp reduce_values(values, %{mode: "collect", path: path}) do
    with {:ok, items} <- reduce_path_values(values, path) do
      {:ok, %{"mode" => "collect", "items" => items, "count" => length(items)}}
    end
  end

  defp reduce_values(values, %{mode: "count"}),
    do: {:ok, %{"mode" => "count", "value" => length(values), "count" => length(values)}}

  defp reduce_values(values, %{mode: "first", path: path}) do
    with {:ok, items} <- reduce_path_values(values, path) do
      {:ok, %{"mode" => "first", "value" => List.first(items), "count" => length(items)}}
    end
  end

  defp reduce_values(values, %{mode: "sum", path: path}) do
    with {:ok, items} <- reduce_path_values(values, path),
         {:ok, total} <- sum_values(items) do
      {:ok, %{"mode" => "sum", "value" => total, "count" => length(items)}}
    end
  end

  defp reduce_values(_values, reduce), do: {:error, {:unsupported_lua_workflow_reduce, reduce}}

  defp reduce_path_values(values, nil), do: {:ok, values}

  defp reduce_path_values(values, path) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case Ref.resolve(%{"value" => %{"var" => "item", "path" => path}}, %{steps: %{}}, %{"item" => value}) do
        {:ok, %{"value" => resolved}} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sum_values(values) do
    values
    |> Enum.reduce_while({:ok, 0}, fn
      value, {:ok, total} when is_integer(value) or is_float(value) -> {:cont, {:ok, total + value}}
      value, _acc -> {:halt, {:error, {:invalid_lua_workflow_sum_value, value}}}
    end)
  end

  defp evaluate_gate("exists", left, _right), do: {:ok, not is_nil(left)}
  defp evaluate_gate("empty", left, _right), do: {:ok, empty?(left)}
  defp evaluate_gate("not_empty", left, _right), do: {:ok, not empty?(left)}
  defp evaluate_gate("eq", left, right), do: {:ok, left == right}
  defp evaluate_gate("neq", left, right), do: {:ok, left != right}
  defp evaluate_gate("gt", left, right) when is_number(left) and is_number(right), do: {:ok, left > right}
  defp evaluate_gate("gte", left, right) when is_number(left) and is_number(right), do: {:ok, left >= right}
  defp evaluate_gate("lt", left, right) when is_number(left) and is_number(right), do: {:ok, left < right}
  defp evaluate_gate("lte", left, right) when is_number(left) and is_number(right), do: {:ok, left <= right}
  defp evaluate_gate("contains", left, right) when is_binary(left), do: {:ok, String.contains?(left, to_string(right))}
  defp evaluate_gate("contains", left, right) when is_list(left), do: {:ok, right in left}
  defp evaluate_gate(op, left, right), do: {:error, {:invalid_lua_workflow_gate, op, left, right}}

  defp ensure_list(values, _field) when is_list(values), do: {:ok, values}
  defp ensure_list(value, field), do: {:error, {:expected_lua_workflow_list, field, value}}

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(%{"passed" => passed}) when is_boolean(passed), do: passed
  defp truthy?(%{passed: passed}) when is_boolean(passed), do: passed
  defp truthy?(_value), do: true

  defp empty?(nil), do: true
  defp empty?(value) when is_binary(value), do: value == ""
  defp empty?(value) when is_list(value), do: value == []
  defp empty?(value) when is_map(value), do: map_size(value) == 0
  defp empty?(_value), do: false

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
