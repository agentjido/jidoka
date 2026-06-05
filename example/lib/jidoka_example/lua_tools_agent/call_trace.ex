defmodule JidokaExample.LuaToolsAgent.CallTrace do
  @moduledoc false

  @spec start_link() :: Agent.on_start()
  def start_link, do: Agent.start_link(fn -> %{calls: [], count: 0, next_id: 1} end)

  @spec calls(pid()) :: [map()]
  def calls(pid) do
    Agent.get(pid, fn state ->
      Enum.map(state.calls, &Map.delete(&1, :id))
    end)
  end

  @spec count(pid()) :: non_neg_integer()
  def count(pid), do: Agent.get(pid, & &1.count)

  @spec reserve(pid(), String.t(), map(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def reserve(pid, tool_id, arguments, max_calls) do
    case reserve_many(pid, [{tool_id, arguments}], max_calls) do
      {:ok, [%{call_id: call_id}]} -> {:ok, call_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reserve_many(pid(), [{String.t(), map()}], pos_integer()) ::
          {:ok, [%{call_id: pos_integer(), tool_id: String.t(), arguments: map()}]}
          | {:error, term()}
  def reserve_many(pid, calls, max_calls) when is_list(calls) do
    Agent.get_and_update(pid, fn state ->
      requested_count = length(calls)

      if state.count + requested_count > max_calls do
        {{:error, {:max_lua_tool_calls_exceeded, max_calls}}, state}
      else
        reserved =
          calls
          |> Enum.with_index(state.next_id)
          |> Enum.map(fn {{tool_id, arguments}, call_id} ->
            %{call_id: call_id, tool_id: tool_id, arguments: arguments}
          end)

        pending =
          Enum.map(reserved, fn %{call_id: call_id, tool_id: tool_id, arguments: arguments} ->
            call_record(call_id, tool_id, arguments, "started", nil)
          end)

        next_state = %{
          state
          | calls: state.calls ++ pending,
            count: state.count + requested_count,
            next_id: state.next_id + requested_count
        }

        {{:ok, reserved}, next_state}
      end
    end)
  end

  @spec complete(pid(), pos_integer(), String.t(), term()) :: :ok
  def complete(pid, call_id, status, output) do
    Agent.update(pid, fn state ->
      calls =
        Enum.map(state.calls, fn
          %{id: ^call_id} = call -> %{call | "status" => status, "output" => output}
          call -> call
        end)

      %{state | calls: calls}
    end)
  end

  defp call_record(call_id, tool_id, arguments, status, output) do
    %{
      :id => call_id,
      "tool" => tool_id,
      "arguments" => arguments,
      "status" => status,
      "output" => output
    }
  end
end
