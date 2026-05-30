defmodule Jidoka.Memory.Store.InMemory do
  @moduledoc """
  In-memory memory store for deterministic tests and examples.
  """

  @behaviour Jidoka.Memory.Store

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Memory.RecallResult
  alias Jidoka.Memory.WriteRequest
  alias Jidoka.Memory.WriteResult

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, opts)
  end

  @impl true
  def recall(%RecallRequest{} = request, opts) do
    pid = fetch_pid!(opts)

    entries =
      pid
      |> Agent.get(& &1)
      |> Enum.filter(&matches_request?(&1, request))
      |> Enum.take(request.limit)

    RecallResult.new(request: request, entries: entries)
  end

  @impl true
  def write(%WriteRequest{entry: %Entry{} = entry} = request, opts) do
    pid = fetch_pid!(opts)

    Agent.update(pid, fn entries ->
      [entry | Enum.reject(entries, &(&1.id == entry.id))]
    end)

    WriteResult.new(request: request, entry: entry)
  end

  @impl true
  def list_entries(opts) do
    pid = fetch_pid!(opts)

    entries =
      pid
      |> Agent.get(& &1)
      |> Enum.reverse()

    {:ok, entries}
  end

  defp matches_request?(%Entry{} = entry, %RecallRequest{} = request) do
    entry.agent_id == request.agent_id and
      session_matches?(entry.session_id, request.session_id, request.scope)
  end

  defp session_matches?(nil, _session_id, :agent), do: true
  defp session_matches?(session_id, session_id, _scope), do: true
  defp session_matches?(_entry_session_id, _request_session_id, _scope), do: false

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "in-memory memory store requires :pid"
    end
  end
end
