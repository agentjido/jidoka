defmodule JidokaExample.LuaToolsAgent.ToolWorkflow do
  @moduledoc false

  require Runic

  alias JidokaExample.LuaToolsAgent.CallTrace
  alias JidokaExample.LuaToolsAgent.Policy
  alias Runic.Workflow

  @type call_spec :: %{tool_id: String.t(), arguments: map()}

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

  defp workflow_context(context, trace) when is_map(context), do: Map.put(context, :trace, trace)
  defp workflow_context(_context, trace), do: %{trace: trace}

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

  defp run_action(action, arguments, context) do
    context = Map.delete(context, :trace)
    tool = action.to_tool()

    case tool.function.(arguments, context) do
      {:ok, encoded} -> {:ok, decode_tool_payload(encoded)}
      {:error, encoded} -> {:error, decode_tool_payload(encoded)}
      other -> {:error, {:invalid_action_result, other}}
    end
  end

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
