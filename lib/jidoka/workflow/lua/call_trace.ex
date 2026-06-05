defmodule Jidoka.Workflow.Lua.CallTrace do
  @moduledoc false

  @spec start_link() :: Agent.on_start()
  def start_link, do: Agent.start_link(fn -> %{calls: [], count: 0, next_id: 1} end)

  @spec calls(pid()) :: [map()]
  def calls(pid) do
    Agent.get(pid, fn state ->
      Enum.map(state.calls, &Map.delete(&1, :id))
    end)
  end

  @spec reserve(pid(), String.t(), map(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def reserve(pid, tool_id, arguments, max_calls) do
    Agent.get_and_update(pid, fn state ->
      if state.count >= max_calls do
        {{:error, {:max_lua_tool_calls_exceeded, max_calls}}, state}
      else
        call_id = state.next_id
        pending = call_record(call_id, tool_id, arguments, "started", nil)

        next_state = %{
          state
          | calls: state.calls ++ [pending],
            count: state.count + 1,
            next_id: call_id + 1
        }

        {{:ok, call_id}, next_state}
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
