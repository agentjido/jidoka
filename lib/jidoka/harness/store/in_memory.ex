defmodule Jidoka.Harness.Store.InMemory do
  @moduledoc """
  In-memory harness store for tests, examples, and local exploration.

  The store is an `Agent` process containing session data keyed by session id.
  It is intentionally small and makes no persistence guarantees.
  """

  @behaviour Jidoka.Harness.Store

  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc "Starts a process-local harness session store."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  def put_session(%Session{} = session, opts) do
    pid = fetch_pid!(opts)

    Agent.get_and_update(pid, fn sessions ->
      case Store.put_transition(Map.get(sessions, session.session_id), session) do
        {:ok, %Session{} = updated} = ok -> {ok, Map.put(sessions, session.session_id, updated)}
        {:error, _reason} = error -> {error, sessions}
      end
    end)
  end

  @impl true
  def get_session(session_id, opts) when is_binary(session_id) do
    pid = fetch_pid!(opts)

    case Agent.get(pid, &Map.get(&1, session_id)) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, {:session_not_found, session_id}}
    end
  end

  @impl true
  def list_sessions(opts) do
    pid = fetch_pid!(opts)

    sessions =
      pid
      |> Agent.get(&Map.values/1)
      |> Enum.sort_by(& &1.session_id)

    {:ok, sessions}
  end

  @impl true
  def claim_session(session_id, %Turn.Request{} = request, opts) when is_binary(session_id) do
    transition(session_id, opts, &Store.claim_transition(&1, request, opts))
  end

  @impl true
  def claim_resume(session_id, opts) when is_binary(session_id) do
    transition(session_id, opts, &Store.resume_transition(&1, opts))
  end

  @impl true
  def recover_session(session_id, opts) when is_binary(session_id) do
    transition(session_id, opts, &Store.recover_transition(&1, opts))
  end

  @impl true
  def checkpoint_session(session_id, lease_id, %AgentSnapshot{} = snapshot, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(session_id, opts, &Store.checkpoint_transition(&1, lease_id, snapshot, opts))
  end

  @impl true
  def commit_session(session_id, lease_id, %Session{} = session, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(session_id, opts, &Store.commit_transition(&1, lease_id, session, opts))
  end

  @impl true
  def renew_session(session_id, lease_id, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(session_id, opts, &Store.renew_transition(&1, lease_id, opts))
  end

  defp transition(session_id, opts, transition) when is_function(transition, 1) do
    pid = fetch_pid!(opts)

    Agent.get_and_update(pid, fn sessions ->
      case Map.get(sessions, session_id) do
        nil ->
          {{:error, {:session_not_found, session_id}}, sessions}

        %Session{} = session ->
          case transition.(session) do
            {:ok, %Session{} = updated} = ok -> {ok, Map.put(sessions, session_id, updated)}
            {:error, _reason} = error -> {error, sessions}
          end
      end
    end)
  end

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "in-memory harness store requires :pid"
    end
  end
end
