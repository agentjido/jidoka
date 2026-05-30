defmodule Jidoka.Trace.Sink.InMemory do
  @moduledoc """
  In-process trace sink for tests, examples, and local inspection.

  This sink is intentionally small and process-local. Durable production sinks
  can implement `Jidoka.Trace.Sink` directly.
  """

  @behaviour Jidoka.Trace.Sink

  alias Jidoka.Trace.Policy

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []), do: Agent.start_link(fn -> [] end, opts)

  @impl true
  def record(entries, %Policy{}, opts) when is_list(entries) do
    with {:ok, pid} <- fetch_pid(opts) do
      Agent.update(pid, &(&1 ++ entries))
    end
  end

  @spec list(pid()) :: [map()]
  def list(pid) when is_pid(pid), do: Agent.get(pid, & &1)

  @spec clear(pid()) :: :ok
  def clear(pid) when is_pid(pid), do: Agent.update(pid, fn _entries -> [] end)

  defp fetch_pid(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:ok, pid} -> {:error, {:invalid_trace_sink_pid, pid}}
      :error -> {:error, :missing_trace_sink_pid}
    end
  end
end
