defmodule Jidoka.Memory.Store.InMemory do
  @moduledoc """
  In-memory memory store for deterministic tests and examples.
  """

  @behaviour Jidoka.Memory.Store

  alias Jidoka.Memory.Entry
  alias Jidoka.Memory.RecallRequest
  alias Jidoka.Memory.RecallResult
  alias Jidoka.Memory.Route
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
      |> Enum.map(&normalize_record/1)
      |> Enum.filter(fn {route, _entry} -> Route.key(route) == Route.key(request.route) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(request.limit)

    RecallResult.new(request: request, entries: entries)
  end

  @impl true
  def write(%WriteRequest{entry: %Entry{} = entry, route: %Route{} = route, idempotency_key: key} = request, opts) do
    pid = fetch_pid!(opts)
    entry = put_idempotency_key(entry, key)

    stored_entry =
      Agent.get_and_update(pid, fn records ->
        records = Enum.map(records, &normalize_record/1)
        stored_entry = idempotent_entry(records, route, entry, key)

        updated =
          [{route, stored_entry} | Enum.reject(records, fn {_route, existing} -> existing.id == stored_entry.id end)]

        {stored_entry, updated}
      end)

    WriteResult.new(request: request, entry: stored_entry)
  end

  defp idempotent_entry(_records, _route, entry, nil), do: entry

  defp idempotent_entry(records, route, entry, key) do
    case Enum.find(records, fn {existing_route, existing} ->
           Route.key(existing_route) == Route.key(route) and idempotency_key(existing) == key
         end) do
      nil -> entry
      {_route, existing} -> existing
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
      |> Enum.map(&normalize_record/1)
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 1))

    {:ok, entries}
  end

  defp normalize_record({%Route{} = route, %Entry{} = entry}), do: {route, entry}

  defp normalize_record(%Entry{agent_id: agent_id, session_id: session_id} = entry)
       when is_binary(session_id),
       do: {Route.new!(kind: :session, agent_id: agent_id, session_id: session_id), entry}

  defp normalize_record(%Entry{agent_id: agent_id} = entry),
    do: {Route.new!(kind: :agent, agent_id: agent_id), entry}

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "in-memory memory store requires :pid"
    end
  end
end
