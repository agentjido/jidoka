defmodule Jidoka.Harness.Store.Dets do
  @moduledoc """
  Disk-backed, lease-aware harness store built on Erlang DETS.

  This adapter is suitable for one BEAM node that needs sessions to survive a
  process or node restart. One GenServer owns the DETS table and serializes all
  lease transitions. Each accepted write calls `:dets.sync/1` before reply.
  Use an external transactional store for multi-node ownership.
  """

  use GenServer

  @behaviour Jidoka.Harness.Store

  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @type option ::
          {:path, Path.t()}
          | {:table, atom()}
          | {:name, GenServer.name()}
          | {:auto_save, non_neg_integer() | :infinity}

  @doc "Starts a disk-backed session store."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         table = Keyword.get(opts, :table, __MODULE__),
         {:ok, ^table} <-
           :dets.open_file(table,
             file: String.to_charlist(path),
             type: :set,
             auto_save: Keyword.get(opts, :auto_save, 5_000),
             repair: true
           ) do
      {:ok, %{table: table, path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    _result = :dets.close(table)
    :ok
  end

  @impl true
  def put_session(%Session{} = session, opts) do
    call(opts, {:put, session})
  end

  @impl true
  def get_session(session_id, opts) when is_binary(session_id) do
    call(opts, {:get, session_id})
  end

  @impl true
  def list_sessions(opts), do: call(opts, :list)

  @impl true
  def claim_session(session_id, %Turn.Request{} = request, opts) when is_binary(session_id) do
    transition(opts, session_id, &Store.claim_transition(&1, request, opts))
  end

  @impl true
  def claim_resume(session_id, opts) when is_binary(session_id) do
    transition(opts, session_id, &Store.resume_transition(&1, opts))
  end

  @impl true
  def recover_session(session_id, opts) when is_binary(session_id) do
    transition(opts, session_id, &Store.recover_transition(&1, opts))
  end

  @impl true
  def checkpoint_session(session_id, lease_id, %AgentSnapshot{} = snapshot, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, session_id, &Store.checkpoint_transition(&1, lease_id, snapshot, opts))
  end

  @impl true
  def commit_session(session_id, lease_id, %Session{} = session, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, session_id, &Store.commit_transition(&1, lease_id, session, opts))
  end

  @impl true
  def renew_session(session_id, lease_id, opts)
      when is_binary(session_id) and is_binary(lease_id) do
    transition(opts, session_id, &Store.renew_transition(&1, lease_id, opts))
  end

  @impl true
  def handle_call({:put, %Session{} = session}, _from, state) do
    current =
      case lookup(state.table, session.session_id) do
        {:ok, %Session{} = current} -> current
        {:error, {:session_not_found, _session_id}} -> nil
      end

    result =
      with {:ok, %Session{} = updated} <- Store.put_transition(current, session) do
        persist(state, updated)
      end

    {:reply, result, state}
  end

  def handle_call({:get, session_id}, _from, state) do
    {:reply, lookup(state.table, session_id), state}
  end

  def handle_call(:list, _from, state) do
    sessions =
      :dets.foldl(fn {_session_id, session}, acc -> [session | acc] end, [], state.table)
      |> Enum.sort_by(& &1.session_id)

    {:reply, {:ok, sessions}, state}
  end

  def handle_call({:transition, session_id, transition}, _from, state) do
    result =
      with {:ok, %Session{} = session} <- lookup(state.table, session_id),
           {:ok, %Session{} = updated} <- transition.(session) do
        persist(state, updated)
      end

    {:reply, result, state}
  end

  defp transition(opts, session_id, transition) when is_function(transition, 1) do
    call(opts, {:transition, session_id, transition})
  end

  defp persist(%{table: table}, %Session{} = session) do
    with :ok <- :dets.insert(table, {session.session_id, session}),
         :ok <- :dets.sync(table) do
      {:ok, session}
    end
  end

  defp lookup(table, session_id) do
    case :dets.lookup(table, session_id) do
      [{^session_id, %Session{} = session}] -> {:ok, session}
      [] -> {:error, {:session_not_found, session_id}}
    end
  end

  defp call(opts, message) do
    opts
    |> fetch_pid!()
    |> GenServer.call(message, Keyword.get(opts, :call_timeout, 5_000))
  end

  defp fetch_pid!(opts) do
    case Keyword.fetch(opts, :pid) do
      {:ok, pid} when is_pid(pid) -> pid
      {:ok, name} when is_atom(name) -> name
      :error -> raise ArgumentError, "DETS harness store requires :pid"
    end
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      {:ok, path} -> {:error, {:invalid_dets_store_path, path}}
      :error -> {:error, :missing_dets_store_path}
    end
  end
end
