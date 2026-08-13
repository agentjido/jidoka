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

  @doc "Starts a process-local memory store."
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
  def write(%WriteRequest{entry: %Entry{} = entry, idempotency_key: key} = request, opts) do
    pid = fetch_pid!(opts)
    entry = put_idempotency_key(entry, key)

    stored_entry =
      Agent.get_and_update(pid, fn entries ->
        stored_entry = idempotent_entry(entries, entry, key)
        updated = [stored_entry | Enum.reject(entries, &(&1.id == stored_entry.id))]
        {stored_entry, updated}
      end)

    WriteResult.new(request: request, entry: stored_entry)
  end

  defp idempotent_entry(_entries, entry, nil), do: entry

  defp idempotent_entry(entries, entry, key) do
    case Enum.find(entries, &(idempotency_key(&1) == key)) do
      nil -> entry
      existing -> existing
    end
  end

  defp put_idempotency_key(entry, nil), do: entry

  defp put_idempotency_key(%Entry{} = entry, key) do
    %Entry{entry | metadata: Map.put(entry.metadata, "idempotency_key", key)}
  end

  defp idempotency_key(%Entry{} = entry) do
    Map.get(entry.metadata, "idempotency_key", Map.get(entry.metadata, :idempotency_key))
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
