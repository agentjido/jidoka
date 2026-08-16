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
    {initial_entries, opts} = Keyword.pop(opts, :initial_entries, [])
    Agent.start_link(fn -> initial_entries end, opts)
  end

  @impl true
  def recall(%RecallRequest{} = request, opts) do
    pid = fetch_pid!(opts)

    entries =
      pid
      |> Agent.get(&normalize_state/1)
      |> Map.fetch!(:entries)
      |> Enum.filter(fn {route, _entry} -> Route.key(route) == Route.key(request.route) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.take(request.limit)

    RecallResult.new(request: request, entries: entries)
  end

  @impl true
  def write(%WriteRequest{entry: %Entry{} = entry, route: %Route{} = route, idempotency_key: key} = request, opts) do
    pid = fetch_pid!(opts)

    stored_entry =
      Agent.get_and_update(pid, fn current ->
        state = normalize_state(current)
        {stored_entry, state} = put_entry(state, route, entry, key)
        {stored_entry, state}
      end)

    WriteResult.new(request: request, entry: stored_entry)
  end

  defp put_entry(state, route, entry, nil) do
    {entry, %{state | entries: upsert_entry(state.entries, route, entry)}}
  end

  defp put_entry(state, route, entry, key) do
    index_key = {Route.key(route), key}

    case Map.fetch(state.idempotency_index, index_key) do
      {:ok, entry_id} ->
        case find_entry(state.entries, route, entry_id) do
          %Entry{} = existing ->
            {existing, state}

          nil ->
            put_new_idempotent_entry(state, route, entry, index_key)
        end

      :error ->
        put_new_idempotent_entry(state, route, entry, index_key)
    end
  end

  defp put_new_idempotent_entry(state, %Route{} = route, %Entry{} = entry, index_key) do
    entry = %Entry{entry | id: idempotency_entry_id(route, entry, elem(index_key, 1))}

    state = %{
      state
      | entries: upsert_entry(state.entries, route, entry),
        idempotency_index: Map.put(state.idempotency_index, index_key, entry.id)
    }

    {entry, state}
  end

  defp upsert_entry(entries, route, entry) do
    route_key = Route.key(route)

    [
      {route, entry}
      | Enum.reject(entries, fn {existing_route, existing} ->
          Route.key(existing_route) == route_key and existing.id == entry.id
        end)
    ]
  end

  defp find_entry(entries, route, entry_id) do
    route_key = Route.key(route)

    case Enum.find(entries, fn {existing_route, entry} ->
           Route.key(existing_route) == route_key and entry.id == entry_id
         end) do
      {_route, entry} -> entry
      nil -> nil
    end
  end

  @impl true
  def list_entries(opts) do
    pid = fetch_pid!(opts)

    entries =
      pid
      |> Agent.get(&normalize_state/1)
      |> Map.fetch!(:entries)
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

  defp normalize_state(%{entries: entries, idempotency_index: index})
       when is_list(entries) and is_map(index),
       do: %{entries: Enum.map(entries, &normalize_record/1), idempotency_index: index}

  # Old process state has entries only. Metadata is opaque, so migration starts
  # with an empty private index instead of treating metadata as dedupe evidence.
  defp normalize_state(entries) when is_list(entries),
    do: %{entries: Enum.map(entries, &normalize_record/1), idempotency_index: %{}}

  defp idempotency_entry_id(_route, %Entry{id: id}, id), do: id

  defp idempotency_entry_id(route, %Entry{}, key),
    do: Jidoka.Id.stable("mem", [Route.key(route), key])

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "in-memory memory store requires :pid"
    end
  end
end
