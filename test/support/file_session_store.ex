defmodule Jidoka.TestSupport.FileSessionStore do
  @moduledoc false

  use GenServer

  @behaviour Jidoka.Session.Store

  alias Jidoka.Session.Data
  alias Jidoka.Session.Transitions
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, sessions} <- load(path) do
      {:ok, %{path: path, sessions: sessions}}
    end
  end

  @impl true
  def put_session(%Data{} = session, opts), do: call(opts, {:put, session, runtime_opts(opts)})

  @impl true
  def get_session(session_id, opts) when is_binary(session_id), do: call(opts, {:get, session_id})

  @impl true
  def list_sessions(opts), do: call(opts, :list)

  @impl true
  def claim_session(session_id, %Turn.Request{} = request, opts) when is_binary(session_id) do
    transition(opts, :claim, session_id, &Transitions.claim(&1, request, opts))
  end

  @impl true
  def claim_resume(session_id, opts) when is_binary(session_id) do
    transition(opts, :resume, session_id, &Transitions.resume(&1, opts))
  end

  @impl true
  def recover_session(session_id, opts) when is_binary(session_id) do
    transition(opts, :recover, session_id, &Transitions.recover(&1, opts))
  end

  @impl true
  def checkpoint_session(session_id, lease_id, %Snapshot{} = snapshot, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, :checkpoint, session_id, &Transitions.checkpoint(&1, lease_id, snapshot, opts))
  end

  @impl true
  def commit_session(session_id, lease_id, %Data{} = completed, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, :commit, session_id, &Transitions.commit(&1, lease_id, completed, opts))
  end

  @impl true
  def renew_session(session_id, lease_id, opts) when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, :renew, session_id, &Transitions.renew(&1, lease_id, opts))
  end

  @impl true
  def handle_call({:put, %Data{} = incoming, opts}, _from, state) do
    current = Map.get(state.sessions, incoming.session_id)

    result =
      with {:ok, %Data{} = updated} <- Transitions.put(current, incoming) do
        persist(state, updated, :put, opts)
      end

    {:reply, result, put_committed(state, result)}
  end

  def handle_call({:get, session_id}, _from, state) do
    result =
      case Map.fetch(state.sessions, session_id) do
        {:ok, %Data{} = session} -> {:ok, session}
        :error -> {:error, {:session_not_found, session_id}}
      end

    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    sessions = state.sessions |> Map.values() |> Enum.sort_by(& &1.session_id)
    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:transition, operation, session_id, transition, opts}, _from, state) do
    result =
      with {:ok, %Data{} = current} <- fetch(state.sessions, session_id),
           {:ok, %Data{} = updated} <- transition.(current) do
        persist(state, updated, operation, opts)
      end

    {:reply, result, put_committed(state, result)}
  end

  defp transition(opts, operation, session_id, transition) when is_function(transition, 1) do
    call(opts, {:transition, operation, session_id, transition, runtime_opts(opts)})
  end

  defp persist(state, %Data{} = updated, operation, opts) do
    sessions = Map.put(state.sessions, updated.session_id, updated)
    temporary = state.path <> ".next"
    binary = :erlang.term_to_binary(sessions, [:deterministic])

    _result = File.rm(temporary)

    with :ok <- write_synced(temporary, binary),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, state.path) do
      notify_synced(opts, operation, updated)
      maybe_crash_after_sync(opts)
      {:ok, updated}
    end
  end

  defp write_synced(path, binary) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          :ok = IO.binwrite(io, binary)
          :file.sync(io)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, binary} -> decode_sessions(binary)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_sessions(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      sessions when is_map(sessions) -> {:ok, sessions}
      _value -> {:error, :invalid_file_session_store}
    end
  rescue
    ArgumentError -> {:error, :invalid_file_session_store}
  end

  defp fetch(sessions, session_id) do
    case Map.fetch(sessions, session_id) do
      {:ok, %Data{} = session} -> {:ok, session}
      :error -> {:error, {:session_not_found, session_id}}
    end
  end

  defp put_committed(state, {:ok, %Data{} = session}) do
    %{state | sessions: Map.put(state.sessions, session.session_id, session)}
  end

  defp put_committed(state, _result), do: state

  defp notify_synced(opts, operation, session) do
    case Keyword.get(opts, :test_pid) do
      pid when is_pid(pid) -> send(pid, {:file_session_store_synced, operation, session})
      _pid -> :ok
    end
  end

  defp maybe_crash_after_sync(opts) do
    if Keyword.get(opts, :crash_after_sync, false), do: Process.exit(self(), :kill)
  end

  defp runtime_opts(opts), do: Keyword.take(opts, [:test_pid, :crash_after_sync])

  defp call(opts, message) do
    opts
    |> Keyword.fetch!(:pid)
    |> GenServer.call(message, Keyword.get(opts, :call_timeout, 5_000))
  end
end
