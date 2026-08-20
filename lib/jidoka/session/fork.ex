defmodule Jidoka.Session.Fork do
  @moduledoc false

  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.EnvironmentRuntime
  alias Jidoka.Session.Lineage
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot

  @doc false
  @spec create(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def create(%Session{} = source, opts) when is_list(opts) do
    with :ok <- ensure_forkable_session(source),
         {:ok, source_snapshot} <- select_snapshot(source, Keyword.get(opts, :snapshot, :latest)),
         {:ok, lineage} <-
           Lineage.next(
             source.lineage,
             source.session_id,
             source_snapshot.snapshot_id,
             clock_ms(opts)
           ),
         {:ok, environment} <- EnvironmentRuntime.fork(source, opts),
         {:ok, fork_snapshot} <- fork_snapshot(source_snapshot, source, lineage, environment, opts),
         {:ok, fork} <- Session.fork(source, fork_snapshot, lineage, session_opts(opts)),
         :ok <- ensure_destination_available(fork, opts) do
      persist(fork, opts)
    end
  end

  defp select_snapshot(%Session{} = session, :latest) do
    case Session.latest_snapshot(session) do
      %Snapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
    end
  end

  defp select_snapshot(%Session{} = session, %Snapshot{} = candidate) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == candidate.snapshot_id)) do
      ^candidate -> {:ok, candidate}
      %Snapshot{} -> {:error, {:session_snapshot_mismatch, candidate.snapshot_id}}
      nil -> {:error, {:session_snapshot_not_found, session.session_id, candidate.snapshot_id}}
    end
  end

  defp select_snapshot(%Session{} = session, snapshot_input) when is_binary(snapshot_input) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == snapshot_input)) do
      %Snapshot{} = snapshot ->
        {:ok, snapshot}

      nil ->
        with {:ok, %Snapshot{} = snapshot} <- Snapshot.from_input(snapshot_input) do
          select_snapshot(session, snapshot)
        end
    end
  end

  defp select_snapshot(%Session{} = session, snapshot_input),
    do: {:error, {:invalid_session_snapshot_selector, session.session_id, snapshot_input}}

  defp fork_snapshot(%Snapshot{} = snapshot, %Session{} = source, lineage, environment, opts) do
    fork_opts =
      [
        snapshot_id: Keyword.get(opts, :fork_snapshot_id),
        id_generator: Keyword.get(opts, :id_generator),
        parent_session_id: source.session_id,
        root_session_id: lineage.root_session_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, %Snapshot{} = fork} <- Snapshot.fork(snapshot, fork_opts) do
      Snapshot.new(%Snapshot{
        fork
        | schema_version: Snapshot.schema_version(),
          environment: environment
      })
    end
  end

  defp ensure_forkable_session(%Session{status: :running, session_id: session_id}),
    do: {:error, {:cannot_fork_running_session, session_id}}

  defp ensure_forkable_session(%Session{}), do: :ok

  defp ensure_destination_available(%Session{} = fork, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> ensure_session_absent(store, fork.session_id)
      :error -> :ok
    end
  end

  defp ensure_session_absent(store, session_id) do
    case Store.get_session(store, session_id) do
      {:error, {:session_not_found, ^session_id}} -> :ok
      {:ok, %Session{}} -> {:error, {:fork_session_already_exists, session_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.put_session(store, session)
      :error -> {:ok, session}
    end
  end

  defp session_opts(opts), do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end
end
