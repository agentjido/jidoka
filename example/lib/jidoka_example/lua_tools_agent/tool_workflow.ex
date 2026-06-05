defmodule JidokaExample.LuaToolsAgent.ToolWorkflow do
  @moduledoc false

  require Runic
  import Runic, only: [context: 1]

  alias JidokaExample.LuaToolsAgent.CallTrace
  alias JidokaExample.LuaToolsAgent.Policy
  alias Runic.Workflow

  @type call_spec :: %{tool_id: String.t(), arguments: map()}
  @type dag_spec :: map()

  @spec run_call(String.t(), map(), pid(), Policy.t(), map()) :: {:ok, term()} | {:error, term()}
  def run_call(tool_id, arguments, trace, %Policy{} = policy, context) do
    case run_calls([%{tool_id: tool_id, arguments: arguments}], trace, policy, context) do
      {:ok, [result]} -> {:ok, result}
      {:ok, other} -> {:error, {:invalid_lua_tool_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_calls([call_spec()], pid(), Policy.t(), map()) :: {:ok, [term()]} | {:error, term()}
  def run_calls([], _trace, %Policy{}, _context), do: {:ok, []}

  def run_calls(call_specs, trace, %Policy{} = policy, context) when is_list(call_specs) do
    with {:ok, calls} <- normalize_calls(call_specs, policy),
         {:ok, reserved} <- reserve_calls(calls, trace, policy),
         {:ok, workflow} <- execute_workflow(reserved, policy, workflow_context(context, trace)) do
      collect_results(workflow, reserved)
    end
  end

  @spec run_dag(dag_spec(), pid(), Policy.t(), map()) :: {:ok, map()} | {:error, term()}
  def run_dag(dag_spec, trace, %Policy{} = policy, context) when is_map(dag_spec) do
    with {:ok, dag} <- normalize_dag(dag_spec, policy),
         {:ok, state} <- execute_dag(dag, trace, policy, workflow_context(context, trace)),
         {:ok, output} <- resolve_output(dag.output, state) do
      {:ok,
       %{
         "workflow_id" => dag.id,
         "output" => output,
         "steps" => state.steps
       }}
    end
  end

  def run_dag(dag_spec, _trace, %Policy{}, _context), do: {:error, {:invalid_lua_workflow, dag_spec}}

  @doc false
  @spec run_dag_step(map() | [map()], map(), pid(), Policy.t(), map()) :: map()
  def run_dag_step(state, step, trace, %Policy{} = policy, context) do
    state
    |> merge_workflow_states()
    |> execute_dag_step(step, trace, policy, context)
  end

  defp workflow_context(context, trace) when is_map(context), do: Map.put(context, :trace, trace)
  defp workflow_context(_context, trace), do: %{trace: trace}

  defp normalize_dag(dag_spec, %Policy{} = policy) do
    allowed = Map.new(policy.entries, &{&1.id, &1})
    workflow_retries = dag_spec |> known_value("retries", 0) |> clamp_retries()
    id = dag_spec |> known_value("id", "lua_workflow") |> to_string()

    with {:ok, raw_steps} <- fetch_steps(dag_spec),
         {:ok, steps} <- normalize_dag_steps(raw_steps, allowed, workflow_retries),
         :ok <- validate_unique_step_ids(steps),
         :ok <- validate_step_ids(steps),
         steps = put_implicit_dependencies(steps),
         :ok <- validate_dependencies(steps),
         :ok <- validate_acyclic_dependencies(steps),
         {:ok, output} <- normalize_output(known_value(dag_spec, "output", nil), steps),
         :ok <- validate_output_refs(output, steps) do
      {:ok, %{id: id, steps: steps, output: output}}
    end
  end

  defp fetch_steps(dag_spec) do
    case known_value(dag_spec, "steps", nil) do
      steps when is_list(steps) and steps != [] -> {:ok, steps}
      steps -> {:error, {:invalid_lua_workflow_steps, steps}}
    end
  end

  defp normalize_dag_steps(raw_steps, allowed, workflow_retries) do
    raw_steps
    |> Enum.reduce_while({:ok, []}, fn raw_step, {:ok, steps} ->
      case normalize_dag_step(raw_step, allowed, workflow_retries) do
        {:ok, step} -> {:cont, {:ok, steps ++ [step]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_dag_step(raw_step, allowed, workflow_retries) when is_map(raw_step) do
    with {:ok, id} <- fetch_step_id(raw_step),
         {:ok, tool_id} <- fetch_step_tool(raw_step),
         {:ok, entry} <- fetch_allowed_entry(allowed, tool_id),
         {:ok, arguments} <- fetch_step_arguments(raw_step),
         {:ok, explicit_after} <- fetch_step_after(raw_step) do
      retries =
        raw_step
        |> known_value("retries", workflow_retries)
        |> clamp_retries()

      {:ok,
       %{
         id: id,
         entry: entry,
         arguments: arguments,
         explicit_after: explicit_after,
         after: explicit_after,
         retries: retries
       }}
    end
  end

  defp normalize_dag_step(raw_step, _allowed, _workflow_retries),
    do: {:error, {:invalid_lua_workflow_step, raw_step}}

  defp fetch_step_id(raw_step) do
    case known_value(raw_step, "id", known_value(raw_step, "name", nil)) do
      id when is_binary(id) -> {:ok, id}
      id when is_atom(id) and not is_nil(id) -> {:ok, Atom.to_string(id)}
      id -> {:error, {:invalid_lua_workflow_step_id, id}}
    end
  end

  defp fetch_step_tool(raw_step) do
    case known_value(raw_step, "tool", known_value(raw_step, "tool_id", nil)) do
      tool_id when is_binary(tool_id) -> {:ok, tool_id}
      path when is_list(path) -> {:ok, Enum.map_join(path, ".", &to_string/1)}
      tool_id -> {:error, {:invalid_lua_workflow_step_tool, tool_id}}
    end
  end

  defp fetch_step_arguments(raw_step) do
    case known_value(raw_step, "arguments", known_value(raw_step, "args", %{})) do
      nil -> {:ok, %{}}
      arguments when is_map(arguments) -> {:ok, arguments}
      arguments -> {:error, {:invalid_lua_workflow_step_arguments, arguments}}
    end
  end

  defp fetch_step_after(raw_step) do
    case known_value(raw_step, "after", known_value(raw_step, "depends_on", [])) do
      nil -> {:ok, []}
      dependencies when is_list(dependencies) -> {:ok, Enum.map(dependencies, &to_string/1)}
      dependency -> {:ok, [to_string(dependency)]}
    end
  end

  defp validate_unique_step_ids(steps) do
    ids = Enum.map(steps, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_lua_workflow_steps, Enum.uniq(duplicates)}}
    end
  end

  defp validate_step_ids(steps) do
    invalid_ids =
      steps
      |> Enum.map(& &1.id)
      |> Enum.reject(&valid_step_id?/1)

    case invalid_ids do
      [] -> :ok
      invalid_ids -> {:error, {:invalid_lua_workflow_step_ids, invalid_ids}}
    end
  end

  defp valid_step_id?(id), do: is_binary(id) and String.match?(id, ~r/^[a-z][a-z0-9_]*$/)

  defp put_implicit_dependencies(steps) do
    Enum.map(steps, fn step ->
      refs = collect_refs(step.arguments)
      Map.put(step, :after, Enum.uniq(step.explicit_after ++ refs))
    end)
  end

  defp collect_refs(value), do: value |> do_collect_refs([]) |> Enum.uniq()

  defp do_collect_refs(%{} = value, refs) do
    case ref_from(value) do
      nil ->
        Enum.reduce(Map.values(value), refs, &do_collect_refs/2)

      step_id ->
        [step_id | refs]
    end
  end

  defp do_collect_refs(values, refs) when is_list(values), do: Enum.reduce(values, refs, &do_collect_refs/2)
  defp do_collect_refs(_value, refs), do: refs

  defp validate_dependencies(steps) do
    step_ids = steps |> Enum.map(& &1.id) |> MapSet.new()

    missing =
      steps
      |> Enum.flat_map(fn step ->
        step.after
        |> Enum.reject(&MapSet.member?(step_ids, &1))
        |> Enum.map(&{step.id, &1})
      end)

    self_dependencies =
      steps
      |> Enum.filter(fn step -> step.id in step.after end)
      |> Enum.map(& &1.id)

    cond do
      missing != [] -> {:error, {:missing_lua_workflow_dependencies, missing}}
      self_dependencies != [] -> {:error, {:self_referential_lua_workflow_steps, self_dependencies}}
      true -> :ok
    end
  end

  defp validate_acyclic_dependencies(steps) do
    graph = Map.new(steps, &{&1.id, &1.after})

    graph
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn step_id, :ok ->
      case visit_step(step_id, graph, MapSet.new(), MapSet.new()) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp visit_step(step_id, graph, visiting, visited) do
    cond do
      MapSet.member?(visited, step_id) ->
        :ok

      MapSet.member?(visiting, step_id) ->
        {:error, {:cyclic_lua_workflow_dependency, step_id}}

      true ->
        visiting = MapSet.put(visiting, step_id)
        visited = MapSet.put(visited, step_id)

        graph
        |> Map.get(step_id, [])
        |> Enum.reduce_while(:ok, fn dependency, :ok ->
          case visit_step(dependency, graph, visiting, visited) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp normalize_output(nil, steps), do: {:ok, %{"from" => steps |> List.last() |> Map.fetch!(:id)}}
  defp normalize_output(output, _steps) when is_binary(output), do: {:ok, %{"from" => output}}
  defp normalize_output(output, _steps), do: {:ok, output}

  defp validate_output_refs(output, steps) do
    step_ids = steps |> Enum.map(& &1.id) |> MapSet.new()

    output
    |> collect_refs()
    |> Enum.reject(&MapSet.member?(step_ids, &1))
    |> case do
      [] -> :ok
      missing -> {:error, {:missing_lua_workflow_output_refs, missing}}
    end
  end

  defp execute_dag(%{steps: steps} = dag, trace, %Policy{} = policy, context) do
    initial_state = %{steps: %{}, error: nil}

    workflow =
      steps
      |> Enum.reduce(Workflow.new(name: dag.id), fn step, workflow ->
        workflow_step =
          Runic.step(
            fn state ->
              __MODULE__.run_dag_step(
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

    final_dag_state(workflow, steps, initial_state)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_dag_step(%{error: error} = state, _step, _trace, _policy, _context) when not is_nil(error),
    do: state

  defp execute_dag_step(state, step, trace, %Policy{} = policy, context) do
    with {:ok, arguments} <- resolve_arguments(step.arguments, state),
         {:ok, output} <- run_action_with_retries(step, arguments, trace, policy, context) do
      put_in(state, [:steps, step.id], output)
    else
      {:error, reason} ->
        %{state | error: {:lua_workflow_step_failed, step.id, reason}}
    end
  end

  defp merge_workflow_states(%{steps: _steps, error: _error} = state), do: state

  defp merge_workflow_states(states) when is_list(states) do
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

  defp merge_workflow_states(state), do: %{steps: %{}, error: {:invalid_lua_workflow_state, state}}

  defp final_dag_state(%Workflow{} = workflow, steps, initial_state) do
    states =
      steps
      |> Enum.flat_map(fn step -> Workflow.raw_productions(workflow, step.id) end)
      |> Enum.filter(&match?(%{steps: _steps, error: _error}, &1))

    state = merge_workflow_states([initial_state | states])

    case state.error do
      nil -> {:ok, state}
      error -> {:error, error}
    end
  end

  defp normalize_calls(call_specs, %Policy{} = policy) do
    allowed = Map.new(policy.entries, &{&1.id, &1})

    call_specs
    |> Enum.reduce_while({:ok, []}, fn call_spec, {:ok, calls} ->
      with {:ok, tool_id} <- fetch_tool_id(call_spec),
           {:ok, entry} <- fetch_allowed_entry(allowed, tool_id),
           {:ok, arguments} <- fetch_arguments(call_spec) do
        {:cont, {:ok, calls ++ [%{entry: entry, arguments: arguments}]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_tool_id(%{tool_id: tool_id}) when is_binary(tool_id), do: {:ok, tool_id}
  defp fetch_tool_id(%{"tool_id" => tool_id}) when is_binary(tool_id), do: {:ok, tool_id}

  defp fetch_tool_id(call_spec) do
    {:error, {:invalid_lua_tool_call, call_spec}}
  end

  defp fetch_allowed_entry(allowed, tool_id) do
    case Map.fetch(allowed, tool_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:lua_tool_not_allowed, tool_id}}
    end
  end

  defp fetch_arguments(%{arguments: arguments}) when is_map(arguments), do: {:ok, arguments}
  defp fetch_arguments(%{"arguments" => arguments}) when is_map(arguments), do: {:ok, arguments}
  defp fetch_arguments(%{arguments: nil}), do: {:ok, %{}}
  defp fetch_arguments(%{"arguments" => nil}), do: {:ok, %{}}

  defp fetch_arguments(call_spec) do
    {:error, {:invalid_lua_tool_arguments, call_spec}}
  end

  defp reserve_calls(calls, trace, %Policy{} = policy) do
    reservations = Enum.map(calls, &{&1.entry.id, &1.arguments})

    with {:ok, reserved} <- CallTrace.reserve_many(trace, reservations, policy.max_calls) do
      calls =
        calls
        |> Enum.zip(reserved)
        |> Enum.with_index()
        |> Enum.map(fn {{call, reservation}, index} ->
          Map.merge(call, %{
            call_id: reservation.call_id,
            step_name: "lua_tool_#{index}"
          })
        end)

      {:ok, calls}
    end
  end

  defp execute_workflow(calls, %Policy{} = policy, context) do
    workflow =
      calls
      |> Enum.reduce(Workflow.new(name: :lua_tool_batch), fn call, workflow ->
        workflow_step =
          Runic.step(
            fn _state ->
              execute_call(^call, ^context)
            end,
            name: call.step_name
          )

        Workflow.add(workflow, workflow_step)
      end)

    workflow =
      Workflow.react_until_satisfied(workflow, %{},
        async: true,
        max_concurrency: policy.max_parallel_calls,
        deadline_ms: policy.timeout_ms,
        timeout: policy.timeout_ms
      )

    {:ok, workflow}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_call(%{entry: entry, arguments: arguments, call_id: call_id}, context) do
    case run_action(entry.module, arguments, context) do
      {:ok, output} ->
        CallTrace.complete(context.trace, call_id, "ok", output)
        {:ok, output}

      {:error, reason} ->
        output = %{"error" => format_reason(reason)}
        CallTrace.complete(context.trace, call_id, "error", output)
        {:error, output["error"]}
    end
  end

  defp run_action_with_retries(step, arguments, trace, %Policy{} = policy, context) do
    max_attempts = step.retries + 1
    do_run_action_with_retries(step, arguments, trace, policy, context, 1, max_attempts)
  end

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

  defp resolve_arguments(arguments, state) when is_map(arguments), do: resolve_value(arguments, state)

  defp resolve_value(%{} = value, state) do
    case ref_from(value) do
      nil ->
        value
        |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, acc} ->
          case resolve_value(nested, state) do
            {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      step_id ->
        resolve_ref(step_id, known_value(value, "path", []), state)
    end
  end

  defp resolve_value(values, state) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case resolve_value(value, state) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_value(value, _state), do: {:ok, value}

  defp resolve_output(output, state) do
    resolve_value(output, state)
  end

  defp resolve_ref(step_id, path, %{steps: steps}) do
    case Map.fetch(steps, step_id) do
      {:ok, output} -> resolve_path(output, normalize_path(path), step_id)
      :error -> {:error, {:missing_lua_workflow_ref, step_id}}
    end
  end

  defp resolve_path(value, [], _step_id), do: {:ok, value}

  defp resolve_path(value, [key | path], step_id) when is_map(value) do
    case fetch_path_key(value, key) do
      {:ok, nested} -> resolve_path(nested, path, step_id)
      :error -> {:error, {:missing_lua_workflow_path, step_id, key}}
    end
  end

  defp resolve_path(value, [key | path], step_id) when is_list(value) do
    with {:ok, index} <- path_index(key),
         {:ok, nested} <- fetch_list_index(value, index) do
      resolve_path(nested, path, step_id)
    else
      :error -> {:error, {:missing_lua_workflow_path, step_id, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_path(value, [key | _path], step_id),
    do: {:error, {:invalid_lua_workflow_path_target, step_id, key, value}}

  defp fetch_path_key(map, key) do
    key = to_string(key)

    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, known_path_atom(key))
    end
  end

  defp known_path_atom("customer_id"), do: :customer_id
  defp known_path_atom("id"), do: :id
  defp known_path_atom("name"), do: :name
  defp known_path_atom("company"), do: :company
  defp known_path_atom("count"), do: :count
  defp known_path_atom("total_due_cents"), do: :total_due_cents
  defp known_path_atom("customers"), do: :customers
  defp known_path_atom("invoices"), do: :invoices
  defp known_path_atom("note"), do: :note
  defp known_path_atom("output"), do: :output
  defp known_path_atom("steps"), do: :steps
  defp known_path_atom(key), do: key

  defp path_index(index) when is_integer(index) and index > 0, do: {:ok, index - 1}

  defp path_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed - 1}
      _other -> :error
    end
  end

  defp path_index(_index), do: :error

  defp fetch_list_index(values, index) do
    case Enum.fetch(values, index) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :error}
    end
  end

  defp normalize_path(nil), do: []
  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path) when is_binary(path), do: String.split(path, ".", trim: true)
  defp normalize_path(path), do: [path]

  defp ref_from(value) when is_map(value) do
    case known_value(value, "from", nil) do
      from when is_binary(from) -> from
      from when is_atom(from) and not is_nil(from) -> Atom.to_string(from)
      _other -> nil
    end
  end

  defp ref_from(_value), do: nil

  defp known_value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_key_atom(key), default)
    end
  end

  defp known_key_atom("after"), do: :after
  defp known_key_atom("arguments"), do: :arguments
  defp known_key_atom("args"), do: :args
  defp known_key_atom("depends_on"), do: :depends_on
  defp known_key_atom("from"), do: :from
  defp known_key_atom("id"), do: :id
  defp known_key_atom("name"), do: :name
  defp known_key_atom("output"), do: :output
  defp known_key_atom("path"), do: :path
  defp known_key_atom("retries"), do: :retries
  defp known_key_atom("steps"), do: :steps
  defp known_key_atom("tool"), do: :tool
  defp known_key_atom("tool_id"), do: :tool_id

  defp clamp_retries(retries) when is_integer(retries), do: retries |> max(0) |> min(2)

  defp clamp_retries(retries) when is_binary(retries) do
    case Integer.parse(retries) do
      {parsed, _rest} -> clamp_retries(parsed)
      :error -> 0
    end
  end

  defp clamp_retries(_retries), do: 0

  defp collect_results(%Workflow{} = workflow, calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, results} ->
      case workflow |> Workflow.raw_productions(call.step_name) |> List.last() do
        {:ok, result} ->
          {:cont, {:ok, results ++ [result]}}

        {:error, reason} ->
          {:halt, {:error, {:lua_tool_call_failed, call.entry.id, reason}}}

        other ->
          {:halt, {:error, {:missing_lua_tool_result, call.entry.id, other}}}
      end
    end)
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
