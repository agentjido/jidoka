defmodule JidokaExamples.IncidentRecoveryCommander.IncidentState do
  @moduledoc false

  def start_link do
    Agent.start_link(fn -> %{counts: %{}, events: []} end)
  end

  def increment(pid, key) when is_pid(pid) and is_atom(key) do
    Agent.get_and_update(pid, fn state ->
      count = Map.get(state.counts, key, 0) + 1
      {count, %{state | counts: Map.put(state.counts, key, count)}}
    end)
  end

  def record(pid, event) when is_pid(pid) do
    Agent.update(pid, fn state -> %{state | events: state.events ++ [event]} end)
  end

  def snapshot(pid) when is_pid(pid), do: Agent.get(pid, & &1)
end
