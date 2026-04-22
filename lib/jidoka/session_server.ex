defmodule Jidoka.SessionServer do
  @moduledoc """
  Single durable writer for MVP session state.

  The server owns durable session/run/attempt/lease persistence and snapshot
  generation. Session processes themselves are intentionally lightweight
  and are started by the session supervisor.
  """

  use GenServer

  alias Jidoka.Attempt
  alias Jidoka.Artifact
  alias Jidoka.AttemptExecution
  alias Jidoka.EnvironmentLease
  alias Jidoka.Event
  alias Jidoka.Bus
  alias Jidoka.Persistence.InMemory
  alias Jidoka.Run
  alias Jidoka.Outcome
  alias Jidoka.Session
  alias Jidoka.SessionProcess
  alias Jidoka.AttemptWorker
  alias Jidoka.Durable
  alias Jidoka.Durable.AttemptStatus
  alias Jidoka.SessionBusPath
  alias Jidoka.Verifier
  alias Jidoka.VerificationResult

  @default_adapter InMemory
  @default_execution_adapter AttemptExecution.NoopAdapter
  @default_verification_adapter Verifier.NoopAdapter
  @core_artifact_types [:diff, :transcript, :command_log, :verifier_report, :prompt_report]
  @server __MODULE__

  defstruct storage_adapter: @default_adapter,
            storage: nil,
            active_sessions: %{}

  @type session_id :: String.t()
  @type session_handle :: String.t() | pid()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @spec open(keyword()) :: {:ok, session_id()} | {:error, term()}
  def open(opts \\ []) do
    GenServer.call(@server, {:open, opts})
  end

  @spec resume(session_handle()) :: {:ok, session_id()} | {:error, term()}
  def resume(session_handle) do
    GenServer.call(@server, {:resume, session_handle})
  end

  @spec close(session_handle()) :: :ok | {:error, term()}
  def close(session_handle) do
    GenServer.call(@server, {:close, session_handle})
  end

  @spec lookup(session_handle()) ::
          {:ok, %{session_ref: session_id(), pid: pid()}} | {:error, term()}
  def lookup(session_handle) do
    GenServer.call(@server, {:lookup, session_handle})
  end

  @spec session_snapshot(session_handle()) ::
          {:ok, map()} | {:error, term()}
  def session_snapshot(session_handle) do
    GenServer.call(@server, {:session_snapshot, session_handle})
  end

  @spec run_snapshot(session_handle(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def run_snapshot(session_handle, run_id) when is_binary(run_id) do
    GenServer.call(@server, {:run_snapshot, session_handle, run_id})
  end

  @spec persist_session(Session.t()) :: :ok | {:error, term()}
  def persist_session(%Session{} = session) do
    GenServer.call(@server, {:persist_session, session})
  end

  @spec persist_run(Run.t()) :: :ok | {:error, term()}
  def persist_run(%Run{} = run) do
    GenServer.call(@server, {:persist_run, run})
  end

  @spec persist_attempt(Attempt.t()) :: :ok | {:error, term()}
  def persist_attempt(%Attempt{} = attempt) do
    GenServer.call(@server, {:persist_attempt, attempt})
  end

  @spec persist_environment_lease(EnvironmentLease.t()) :: :ok | {:error, term()}
  def persist_environment_lease(%EnvironmentLease{} = lease) do
    GenServer.call(@server, {:persist_environment_lease, lease})
  end

  @spec persist_attempt_artifacts(String.t(), [map()]) :: :ok | {:error, term()}
  def persist_attempt_artifacts(attempt_id, artifact_specs) when is_binary(attempt_id) do
    GenServer.call(@server, {:persist_attempt_artifacts, attempt_id, artifact_specs})
  end

  @spec submit(session_handle(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def submit(session_handle, task, opts \\ []) when is_binary(task) do
    GenServer.call(@server, {:submit, session_handle, task, opts})
  end

  @spec mark_attempt_running(String.t()) :: :ok | {:error, term()}
  def mark_attempt_running(attempt_id) when is_binary(attempt_id) do
    GenServer.call(@server, {:mark_attempt_running, attempt_id})
  end

  @spec mark_attempt_progress(String.t(), map()) :: :ok | {:error, term()}
  def mark_attempt_progress(attempt_id, payload) when is_binary(attempt_id) and is_map(payload) do
    GenServer.call(@server, {:mark_attempt_progress, attempt_id, payload})
  end

  @spec mark_attempt_completed(String.t(), map()) :: :ok | {:error, term()}
  def mark_attempt_completed(attempt_id, metadata)
      when is_binary(attempt_id) and is_map(metadata) do
    GenServer.call(@server, {:mark_attempt_completed, attempt_id, metadata})
  end

  @spec mark_attempt_failed(String.t(), AttemptStatus.t(), term(), map()) ::
          :ok | {:error, term()}
  def mark_attempt_failed(attempt_id, status, reason, metadata)
      when is_binary(attempt_id) and is_map(metadata) and
             status in [:retryable_failed, :terminal_failed] do
    GenServer.call(@server, {:mark_attempt_failed, attempt_id, status, reason, metadata})
  end

  @spec approve(session_handle(), String.t()) :: :ok | {:error, term()}
  def approve(session_handle, run_id) when is_binary(run_id) do
    GenServer.call(@server, {:approve, session_handle, run_id})
  end

  @spec reject(session_handle(), String.t()) :: :ok | {:error, term()}
  def reject(session_handle, run_id) when is_binary(run_id) do
    GenServer.call(@server, {:reject, session_handle, run_id})
  end

  @spec retry(session_handle(), String.t(), keyword()) :: :ok | {:error, term()}
  def retry(session_handle, run_id, opts \\ []) when is_binary(run_id) do
    GenServer.call(@server, {:retry, session_handle, run_id, opts})
  end

  @spec cancel(session_handle(), String.t()) :: :ok | {:error, term()}
  def cancel(session_handle, run_id) when is_binary(run_id) do
    GenServer.call(@server, {:cancel, session_handle, run_id})
  end

  @spec mark_verification_completed(String.t(), VerificationResult.t()) :: :ok | {:error, term()}
  def mark_verification_completed(attempt_id, %VerificationResult{} = verification_result)
      when is_binary(attempt_id) do
    GenServer.call(@server, {:mark_verification_completed, attempt_id, verification_result})
  end

  @impl true
  def init(opts) do
    adapter = Keyword.get(opts, :storage_adapter, @default_adapter)
    storage = Keyword.get(opts, :storage, adapter.new())

    {:ok,
     %__MODULE__{
       storage_adapter: adapter,
       storage: storage,
       active_sessions: %{}
     }}
  end

  @impl true
  def handle_call({:open, opts}, _from, state) do
    with {:ok, session_id, session} <- session_from_opts(state, opts),
         {:ok, state} <- ensure_session_process(state, session_id),
         {:ok, state} <- maybe_persist_new_session(state, session_id, session),
         {:ok, state} <- reconcile_session_attempts(state, session_id) do
      {:reply, {:ok, session_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:resume, session_handle}, _from, state) do
    case resolve_session_id(state, session_handle) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, session_id} ->
        with {:ok, state} <- ensure_session_process(state, session_id),
             {:ok, state} <- ensure_loaded(state, session_id),
             {:ok, state} <- reconcile_session_attempts(state, session_id) do
          {:reply, {:ok, session_id}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:close, session_handle}, _from, state) do
    case resolve_session_id(state, session_handle) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, session_id} ->
        state = remove_active_session(state, session_id)

        with {:ok, session} <- state.storage_adapter.load_session(state.storage, session_id),
             {:ok, storage} <- publish_and_store_session(state, %{session | status: :closed}) do
          {:reply, :ok, %{state | storage: storage}}
        else
          {:error, :not_found} -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:lookup, session_handle}, _from, state) do
    case resolve_session_id(state, session_handle) do
      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}

      {:ok, session_id} ->
        case Map.get(state.active_sessions, session_id) do
          pid when is_pid(pid) ->
            if Process.alive?(pid) do
              {:reply, {:ok, %{session_ref: session_id, pid: pid}}, state}
            else
              {:reply, {:error, :not_found}, state}
            end

          _ ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:session_snapshot, session_handle}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, envelope} <- state.storage_adapter.load_session_envelope(state.storage, session_id),
         {:ok, _session} <- state.storage_adapter.load_session(state.storage, session_id) do
      {:reply, {:ok, session_snapshot_map(envelope)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:run_snapshot, session_handle, run_id}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, envelope} <- state.storage_adapter.load_session_envelope(state.storage, session_id),
         {:ok, run_snapshot} <- run_snapshot_from_envelope(envelope, run_id) do
      {:reply, {:ok, run_snapshot}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:persist_session, session}, _from, state) do
    case persist_session_record(state, session) do
      {:ok, state} ->
        maybe_publish(session.id, :session_updated, %{operation: :save_session})
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:persist_run, run}, _from, state) do
    with {:ok, state} <- persist_run_record(state, run) do
      maybe_publish(run.session_id, :run_updated, %{run_id: run.id, operation: :save_run})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:persist_attempt, attempt}, _from, state) do
    with {:ok, state} <- persist_attempt_record(state, attempt) do
      run_id = attempt.run_id
      maybe_publish(run_id, :attempt_saved, %{attempt_id: attempt.id})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:persist_environment_lease, lease}, _from, state) do
    with {:ok, state} <- persist_environment_lease_record(state, lease) do
      maybe_publish(
        lease.attempt_id,
        :environment_lease_saved,
        %{attempt_id: lease.attempt_id, lease_id: lease.id}
      )

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:persist_attempt_artifacts, attempt_id, artifact_specs}, _from, state) do
    with {:ok, state} <- persist_attempt_artifacts(state, attempt_id, artifact_specs) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_attempt_running, attempt_id}, _from, state) do
    with {:ok, state} <-
           update_attempt_status(
             state,
             attempt_id,
             :running,
             status_started_at: now(),
             event_type: :attempt_started,
             event_payload: %{status: :running},
             output_metadata: %{execution_phase: :running}
           ) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_attempt_progress, attempt_id, payload}, _from, state) do
    with {:ok, state} <- append_attempt_progress_event(state, attempt_id, payload) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_attempt_completed, attempt_id, metadata}, _from, state) do
    with {:ok, state} <-
           update_attempt_status(
             state,
             attempt_id,
             :succeeded,
             status_finished_at: now(),
             event_type: :attempt_completed,
             event_payload: %{status: :succeeded},
             output_metadata: metadata
           ) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:mark_attempt_failed, attempt_id, status, reason, metadata}, _from, state) do
    with {:ok, state} <-
           update_attempt_status(
             state,
             attempt_id,
             status,
             status_finished_at: now(),
             event_type: :attempt_failed,
             event_payload: %{status: status, reason: reason},
             output_metadata: Map.put(metadata, :execution_failure_reason, reason)
           ) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:approve, session_handle, run_id}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, run_id),
         :ok <- validate_run_ownership(run, session_id),
         {:ok, state} <- apply_approve_command(state, run) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:reject, session_handle, run_id}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, run_id),
         :ok <- validate_run_ownership(run, session_id),
         {:ok, state} <- apply_reject_command(state, run) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:retry, session_handle, run_id, opts}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, session} <- state.storage_adapter.load_session(state.storage, session_id),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, run_id),
         :ok <- validate_run_ownership(run, session_id),
         {:ok, state} <- apply_retry_command(state, run, session, opts) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:cancel, session_handle, run_id}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, run_id),
         :ok <- validate_run_ownership(run, session_id),
         {:ok, state} <- apply_cancel_command(state, run) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(
        {:mark_verification_completed, attempt_id, %VerificationResult{} = result},
        _from,
        state
      ) do
    with {:ok, state} <- persist_verification_completed(state, attempt_id, result) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:submit, session_handle, task, opts}, _from, state) do
    with {:ok, session_id} <- resolve_session_id(state, session_handle),
         {:ok, session} <- state.storage_adapter.load_session(state.storage, session_id),
         {:ok, run} <- build_submit_run(session_id, task, opts),
         {:ok, state} <- persist_run_record(state, run),
         {:ok, attempt} <- build_submit_attempt(run.id, run.task_pack, opts),
         {:ok, state} <- persist_attempt_record(state, attempt),
         {:ok, lease} <- build_submit_lease(session, run, attempt, opts),
         {:ok, state} <- persist_environment_lease_record(state, lease),
         {:ok, state} <- append_run_submitted_event(state, session_id, run, attempt),
         {:ok, state} <- start_attempt_worker(state, session_id, run, attempt, lease, opts) do
      {:reply, {:ok, %{run: run, attempt: attempt, lease: lease}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_from_opts(state, opts) do
    session_id = Keyword.get(opts, :id, generate_id("session"))
    workspace_path = Keyword.get(opts, :workspace_path, Keyword.get(opts, :cwd))
    metadata = Keyword.get(opts, :metadata, %{})
    status = Keyword.get(opts, :status, :initializing)

    case state.storage_adapter.load_session(state.storage, session_id) do
      {:ok, session} ->
        {:ok, session_id, session}

      {:error, :not_found} ->
        case Session.new(
               id: session_id,
               status: status,
               workspace_path: workspace_path,
               metadata: metadata
             ) do
          {:ok, session} -> {:ok, session_id, session}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_persist_new_session(state, session_id, session) do
    case state.storage_adapter.load_session(state.storage, session_id) do
      {:ok, _} ->
        {:ok, state}

      {:error, :not_found} ->
        with {:ok, storage} <- state.storage_adapter.save_session(state.storage, session),
             {:ok, storage_record, _event_record} <-
               append_event_record(state, storage, :session_opened, session_id, %{action: :open}) do
          :ok = maybe_publish(session_id, :session_opened, %{})
          {:ok, %{state | storage: storage_record}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_loaded(state, session_id) do
    case state.storage_adapter.load_session(state.storage, session_id) do
      {:ok, _session} -> {:ok, state}
      {:error, :not_found} -> {:error, :not_found}
      error -> error
    end
  end

  defp ensure_session_process(state, session_id) do
    case Map.get(state.active_sessions, session_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, state}
        else
          start_session_process(state, session_id)
        end

      _ ->
        start_session_process(state, session_id)
    end
  end

  defp start_session_process(state, session_id) do
    case ensure_existing_process_started(state, session_id) do
      {:ok, pid} ->
        {:ok, %{state | active_sessions: Map.put(state.active_sessions, session_id, pid)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_existing_process_started(_state, session_id) do
    case DynamicSupervisor.start_child(Jidoka.SessionSupervisor, {SessionProcess, session_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_present, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_active_session(state, session_id) do
    case Map.get(state.active_sessions, session_id) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        %{state | active_sessions: Map.delete(state.active_sessions, session_id)}

      _ ->
        %{state | active_sessions: Map.delete(state.active_sessions, session_id)}
    end
  end

  defp reconcile_session_attempts(state, session_id) do
    with {:ok, envelope} <- state.storage_adapter.load_session_envelope(state.storage, session_id) do
      attempts_by_id = Map.new(envelope.attempts, &{&1.id, &1})
      leases_by_attempt = Map.new(envelope.leases, &{&1.attempt_id, &1})

      envelope.runs
      |> Enum.filter(&(&1.status in [:queued, :running]))
      |> Enum.reduce_while({:ok, state}, fn run, {:ok, acc_state} ->
        case Map.get(attempts_by_id, run.latest_attempt_id) do
          %Attempt{status: status} = attempt when status in [:pending, :running] ->
            if attempt_worker_running?(attempt.id) do
              {:cont, {:ok, acc_state}}
            else
              {:cont,
               reconcile_orphaned_attempt(
                 acc_state,
                 run,
                 attempt,
                 Map.get(leases_by_attempt, attempt.id)
               )}
            end

          _ ->
            {:cont, {:ok, acc_state}}
        end
      end)
    else
      {:error, :not_found} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_orphaned_attempt(state, run, attempt, lease) do
    cond do
      attempt.status == :pending ->
        reconcile_pending_attempt(state, run, attempt, lease)

      attempt.status == :running ->
        reconcile_running_attempt(state, run, attempt, lease)

      true ->
        {:ok, state}
    end
  end

  defp reconcile_pending_attempt(state, run, attempt, nil) do
    updated_attempt =
      %{
        attempt
        | metadata: Map.put(attempt.metadata, :orphaned_recovery, :pending_worker_missing)
      }

    with {:ok, state} <- persist_attempt_record(state, updated_attempt),
         {:ok, state} <-
           append_run_updated_event(
             state,
             run,
             :attempt_recovered,
             attempt_id: attempt.id,
             strategy: :mark_for_review,
             reason: :orphaned_workspace_lease_missing
           ) do
      {:ok, state}
    end
  end

  defp reconcile_pending_attempt(state, run, attempt, lease) do
    with {:ok, state} <- start_attempt_worker(state, run.session_id, run, attempt, lease, []) do
      append_run_updated_event(state, run, :attempt_recovered,
        attempt_id: attempt.id,
        strategy: :reattach
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_running_attempt(state, _run, attempt, lease) do
    with {:ok, state} <-
           update_attempt_status(
             state,
             attempt.id,
             :terminal_failed,
             status_finished_at: now(),
             event_type: :attempt_failed,
             event_payload: %{status: :terminal_failed, reason: :orphaned_running_worker},
             output_metadata: %{
               orphaned_recovery: :running_worker_missing,
               recovery_source: :resume
             }
           ),
         {:ok, recovered_run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         {:ok, state} <- mark_orphaned_lease(state, lease, attempt.id),
         {:ok, state} <-
           append_run_updated_event(
             state,
             recovered_run,
             :attempt_recovered,
             attempt_id: attempt.id,
             strategy: :cleanup
           ) do
      {:ok, state}
    end
  end

  defp mark_orphaned_lease(state, nil, _attempt_id), do: {:ok, state}

  defp mark_orphaned_lease(state, %EnvironmentLease{} = lease, attempt_id) do
    cleanup_status = cleanup_orphaned_workspace_path(lease.workspace_path)

    lease_metadata =
      (lease.metadata || %{})
      |> Map.put(:orphaned_recovery, :running_worker_missing)
      |> Map.put(:orphaned_attempt_id, attempt_id)
      |> Map.put(:orphaned_cleanup_status, cleanup_status)

    recovered_lease = %{
      lease
      | status: :expired,
        updated_at: now(),
        metadata: lease_metadata
    }

    with {:ok, storage} <-
           state.storage_adapter.save_environment_lease(state.storage, recovered_lease) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp cleanup_orphaned_workspace_path(nil), do: :not_applicable

  defp cleanup_orphaned_workspace_path(path) when is_binary(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :removed
      {:error, reason, _path} -> {:failed, reason}
    end
  end

  defp attempt_worker_running?(attempt_id) do
    match?([_ | _], Registry.lookup(Jidoka.Registry, {:attempt, attempt_id}))
  end

  defp resolve_session_id(_state, session_handle) when is_binary(session_handle) do
    {:ok, session_handle}
  end

  defp resolve_session_id(state, session_handle) when is_pid(session_handle) do
    state.active_sessions
    |> Enum.find_value(fn {session_id, pid} ->
      if(pid == session_handle, do: session_id, else: nil)
    end)
    |> case do
      nil -> {:error, :not_found}
      session_id -> {:ok, session_id}
    end
  end

  defp resolve_session_id(_state, _session_handle), do: {:error, :invalid_session_handle}

  defp persist_session_record(state, %Session{} = session) do
    with {:ok, storage} <- state.storage_adapter.save_session(state.storage, session) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp persist_run_record(state, %Run{} = run) do
    with {:ok, session} <- state.storage_adapter.load_session(state.storage, run.session_id),
         {:ok, run_ids} <- ensure_member(session.run_ids, run.id),
         updated_session <- %{session | run_ids: run_ids, active_run_id: run.id},
         {:ok, storage} <- state.storage_adapter.save_session(state.storage, updated_session),
         {:ok, storage} <- state.storage_adapter.save_run(storage, run) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp persist_attempt_record(state, %Attempt{} = attempt) do
    with {:ok, run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         {:ok, attempt_ids} <- ensure_member(run.attempt_ids, attempt.id),
         updated_run <- %{run | attempt_ids: attempt_ids, latest_attempt_id: attempt.id},
         {:ok, storage} <- state.storage_adapter.save_run(state.storage, updated_run),
         {:ok, storage} <- state.storage_adapter.save_attempt(storage, attempt) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp persist_environment_lease_record(state, %EnvironmentLease{} = lease) do
    with {:ok, attempt} <- state.storage_adapter.load_attempt(state.storage, lease.attempt_id),
         updated_attempt <- %{attempt | environment_lease_id: lease.id},
         {:ok, storage} <- state.storage_adapter.save_attempt(state.storage, updated_attempt),
         {:ok, storage} <- state.storage_adapter.save_environment_lease(storage, lease) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp start_attempt_worker(state, session_id, run, attempt, lease, opts) do
    attempt_adapter = execution_adapter_for_attempt(attempt, opts)
    verifier_adapter = verifier_adapter_for_attempt(attempt, run, opts)

    attempt_spec =
      %AttemptExecution.AttemptSpec{
        session_id: session_id,
        run_id: run.id,
        attempt_id: attempt.id,
        task: run.task,
        attempt_number: attempt.attempt_number,
        task_pack: run.task_pack,
        environment_lease: lease,
        metadata: Map.put(attempt.metadata || %{}, :source, :attempt_worker),
        adapter: attempt_adapter,
        verification_adapter: verifier_adapter
      }

    case DynamicSupervisor.start_child(
           Jidoka.AttemptSupervisor,
           {AttemptWorker, attempt_spec}
         ) do
      {:ok, _pid} ->
        {:ok, state}

      {:error, {:already_started, _pid}} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_approve_command(state, %Run{} = run) do
    with :ok <- ensure_run_status(run.status, :awaiting_approval, :approve),
         :ok <- validate_run_transition(run.status, :completed),
         {:ok, attempt} <- load_latest_attempt(state.storage_adapter, state.storage, run),
         :ok <- ensure_attempt_status(attempt.status, [:succeeded], :approve),
         updated_run <- %{
           run
           | status: :completed,
             outcome: :approved,
             artifact_ids: attempt.artifact_ids,
             updated_at: now()
         },
         {:ok, state} <- persist_run_record(state, updated_run),
         {:ok, state} <-
           persist_outcome_record(state, updated_run, attempt.id, :approved, "approved"),
         {:ok, state} <-
           append_run_updated_event(state, updated_run, :approve, attempt_id: attempt.id) do
      {:ok, state}
    end
  end

  defp apply_reject_command(state, %Run{} = run) do
    with :ok <- ensure_run_status(run.status, :awaiting_approval, :reject),
         {:ok, attempt} <- load_latest_attempt(state.storage_adapter, state.storage, run),
         :ok <- ensure_attempt_status(attempt.status, [:succeeded], :reject),
         updated_run <- %{
           run
           | status: :failed,
             outcome: :terminal_failed,
             updated_at: now()
         },
         {:ok, state} <- persist_run_record(state, updated_run),
         {:ok, state} <-
           persist_outcome_record(state, updated_run, attempt.id, :terminal_failed, "rejected"),
         {:ok, state} <-
           append_run_updated_event(state, updated_run, :reject, attempt_id: attempt.id) do
      {:ok, state}
    end
  end

  defp apply_retry_command(state, %Run{} = run, %Session{} = session, opts) do
    with :ok <- ensure_run_status(run.status, :failed, :retry),
         :ok <- ensure_retryable_outcome(run.outcome, :retry),
         :ok <- validate_run_transition(run.status, :queued),
         {:ok, previous_attempt} <- load_latest_attempt(state.storage_adapter, state.storage, run),
         :ok <-
           ensure_attempt_status(previous_attempt.status, [:succeeded, :retryable_failed], :retry),
         updated_run <- %{run | status: :queued, outcome: nil, updated_at: now()},
         {:ok, state} <- persist_run_record(state, updated_run),
         {:ok, attempt} <- build_retry_attempt(run.id, previous_attempt, opts),
         {:ok, state} <- persist_attempt_record(state, attempt),
         {:ok, lease} <- build_submit_lease(session, updated_run, attempt, opts),
         {:ok, state} <- persist_environment_lease_record(state, lease),
         {:ok, state} <-
           append_run_updated_event(state, updated_run, :retry,
             attempt_id: attempt.id,
             previous_attempt_id: previous_attempt.id
           ),
         {:ok, state} <-
           start_attempt_worker(state, session.id, updated_run, attempt, lease, opts) do
      {:ok, state}
    end
  end

  defp apply_cancel_command(state, %Run{} = run) do
    with :ok <- ensure_run_status(run.status, [:queued, :running], :cancel),
         {:ok, attempt} <- load_latest_attempt(state.storage_adapter, state.storage, run),
         :ok <- ensure_attempt_status(attempt.status, [:pending, :running], :cancel),
         :ok <- stop_attempt_worker(attempt.id),
         {:ok, state} <- mark_attempt_canceled(state, attempt),
         updated_run <- %{run | status: :canceled, outcome: :canceled, updated_at: now()},
         {:ok, state} <- persist_run_record(state, updated_run),
         {:ok, state} <-
           persist_outcome_record(state, updated_run, attempt.id, :canceled, "canceled"),
         {:ok, state} <-
           append_run_updated_event(state, updated_run, :cancel, attempt_id: attempt.id) do
      {:ok, state}
    end
  end

  defp mark_attempt_canceled(state, %Attempt{} = attempt) do
    update_attempt_status(
      state,
      attempt.id,
      :canceled,
      status_finished_at: now(),
      event_type: :attempt_failed,
      event_payload: %{status: :canceled, reason: :operator_cancel},
      output_metadata: %{cancellation_reason: :operator}
    )
  end

  defp stop_attempt_worker(attempt_id) do
    case AttemptWorker.stop(attempt_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp load_latest_attempt(_storage_adapter, _storage, %Run{latest_attempt_id: nil}) do
    {:error, :attempt_not_found}
  end

  defp load_latest_attempt(storage_adapter, storage, %Run{} = run) do
    storage_adapter.load_attempt(storage, run.latest_attempt_id)
  end

  defp validate_run_ownership(%Run{session_id: session_id}, session_id), do: :ok

  defp validate_run_ownership(%Run{}, _), do: {:error, :invalid_run_ownership}

  defp ensure_run_status(current_status, expected_status, action) when is_atom(expected_status) do
    if current_status == expected_status do
      :ok
    else
      {:error, {:invalid_run_status_for_action, action, expected_status, current_status}}
    end
  end

  defp ensure_run_status(current_status, expected_statuses, action)
       when is_list(expected_statuses) do
    if current_status in expected_statuses do
      :ok
    else
      {:error, {:invalid_run_status_for_action, action, expected_statuses, current_status}}
    end
  end

  defp ensure_attempt_status(current_status, expected_statuses, action) do
    if current_status in expected_statuses do
      :ok
    else
      {:error, {:invalid_attempt_status_for_action, action, expected_statuses, current_status}}
    end
  end

  defp ensure_retryable_outcome(:retryable_failed, :retry), do: :ok

  defp ensure_retryable_outcome(outcome, :retry),
    do: {:error, {:invalid_run_outcome_for_action, :retry, :retryable_failed, outcome}}

  defp append_run_updated_event(state, %Run{} = run, operation, opts) do
    payload =
      opts
      |> Keyword.merge(
        run_id: run.id,
        operation: operation,
        parent_run_id: run.parent_run_id,
        role: run.role
      )
      |> Map.new()

    with {:ok, storage_record, _event_record} <-
           append_event_record(state, state.storage, :run_updated, run.session_id, payload,
             run_id: run.id,
             parent_run_id: run.parent_run_id,
             role: run.role
           ) do
      {:ok, %{state | storage: storage_record}}
    end
  end

  defp persist_outcome_record(
         state,
         %Run{} = run,
         attempt_id,
         outcome,
         notes
       ) do
    with {:ok, outcome_record} <-
           Outcome.new(
             id: generate_id("outcome"),
             run_id: run.id,
             attempt_id: attempt_id,
             outcome: outcome,
             notes: notes
           ),
         {:ok, storage} <- state.storage_adapter.save_outcome(state.storage, outcome_record) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp build_retry_attempt(run_id, %Attempt{} = previous_attempt, opts) do
    base_metadata =
      previous_attempt.metadata
      |> Map.drop([
        :verification_adapter,
        "verification_adapter",
        :execution_phase,
        "execution_phase",
        :execution_failure_reason,
        "execution_failure_reason"
      ])

    Attempt.new(
      id: Keyword.get(opts, :attempt_id, generate_id("attempt")),
      run_id: run_id,
      attempt_number: previous_attempt.attempt_number + 1,
      status: Keyword.get(opts, :attempt_status, :pending),
      metadata: Map.merge(base_metadata, Keyword.get(opts, :attempt_metadata, %{}))
    )
  end

  defp update_attempt_status(
         state,
         attempt_id,
         status,
         opts
       ) do
    started_at = Keyword.get(opts, :status_started_at)
    finished_at = Keyword.get(opts, :status_finished_at)
    output_metadata = Keyword.get(opts, :output_metadata, %{})
    event_type = Keyword.fetch!(opts, :event_type)
    event_payload = Keyword.get(opts, :event_payload, %{})

    with {:ok, attempt} <- state.storage_adapter.load_attempt(state.storage, attempt_id),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         :ok <- validate_attempt_transition(attempt.status, status),
         {:ok, state, run} <- transition_run_for_attempt(state, run, attempt.status, status),
         updated_attempt <-
           %{
             attempt
             | status: status,
               started_at: started_at || attempt.started_at,
               finished_at: finished_at || attempt.finished_at,
               metadata: merge_metadata(attempt.metadata, output_metadata),
               updated_at: now()
           },
         {:ok, state} <- persist_attempt_record(state, updated_attempt),
         {:ok, storage, _event_record} <-
           append_event_record(
             state,
             state.storage,
             event_type,
             run.session_id,
             Map.merge(
               %{
                 run_id: run.id,
                 attempt_id: attempt.id,
                 parent_run_id: run.parent_run_id,
                 role: run.role,
                 status: status,
                 started_at: updated_attempt.started_at,
                 finished_at: updated_attempt.finished_at
               },
               event_payload
             ),
             run_id: run.id,
             parent_run_id: run.parent_run_id,
             role: run.role,
             attempt_id: attempt.id
           ) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp validate_attempt_transition(:pending, :running), do: :ok
  defp validate_attempt_transition(:pending, :canceled), do: :ok
  defp validate_attempt_transition(:running, :succeeded), do: :ok
  defp validate_attempt_transition(:running, :retryable_failed), do: :ok
  defp validate_attempt_transition(:running, :terminal_failed), do: :ok
  defp validate_attempt_transition(:running, :canceled), do: :ok

  defp validate_attempt_transition(current, next),
    do: {:error, {:illegal_attempt_transition, current, next}}

  defp transition_run_for_attempt(state, run, :pending, :running) do
    transition_run_if_needed(state, run, :running)
  end

  defp transition_run_for_attempt(state, run, _attempt_status, :retryable_failed) do
    transition_run_for_termination(state, run, :retryable_failed)
  end

  defp transition_run_for_attempt(state, run, _attempt_status, :terminal_failed) do
    transition_run_for_termination(state, run, :terminal_failed)
  end

  defp transition_run_for_attempt(state, run, _attempt_status, :canceled) do
    transition_run_if_needed(state, run, :canceled)
  end

  defp transition_run_for_attempt(state, run, _attempt_status, _next_status) do
    {:ok, state, run}
  end

  defp transition_run_if_needed(state, run, next_status) do
    with :ok <- validate_run_transition(run.status, next_status) do
      updated_run = %{run | status: next_status, updated_at: now()}

      with {:ok, state} <- persist_run_record(state, updated_run) do
        {:ok, state, updated_run}
      end
    end
  end

  defp transition_run_for_termination(state, run, outcome) do
    with :ok <- validate_run_transition(run.status, :failed) do
      updated_run = %{run | status: :failed, outcome: outcome, updated_at: now()}

      with {:ok, state} <- persist_run_record(state, updated_run) do
        {:ok, state, updated_run}
      end
    end
  end

  defp append_attempt_progress_event(state, attempt_id, payload) do
    with {:ok, attempt} <- state.storage_adapter.load_attempt(state.storage, attempt_id),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         {:ok, storage, _event_record} <-
           append_event_record(
             state,
             state.storage,
             :attempt_progress,
             run.session_id,
             Map.merge(
               %{
                 run_id: run.id,
                 attempt_id: attempt.id,
                 parent_run_id: run.parent_run_id,
                 role: run.role
               },
               payload
             ),
             run_id: run.id,
             parent_run_id: run.parent_run_id,
             role: run.role,
             attempt_id: attempt.id
           ) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp validate_run_transition(:queued, :running), do: :ok
  defp validate_run_transition(:running, :awaiting_approval), do: :ok
  defp validate_run_transition(:running, :failed), do: :ok
  defp validate_run_transition(:running, :canceled), do: :ok
  defp validate_run_transition(:awaiting_approval, :completed), do: :ok
  defp validate_run_transition(:awaiting_approval, :failed), do: :ok
  defp validate_run_transition(:awaiting_approval, :canceled), do: :ok
  defp validate_run_transition(:queued, :canceled), do: :ok
  defp validate_run_transition(:failed, :queued), do: :ok

  defp validate_run_transition(current, next),
    do: {:error, {:illegal_run_transition, current, next}}

  defp merge_metadata(nil, overrides), do: Map.merge(%{}, overrides)
  defp merge_metadata(base, overrides), do: Map.merge(base, overrides)

  defp publish_and_store_session(state, %Session{} = session) do
    with {:ok, storage} <- state.storage_adapter.save_session(state.storage, session) do
      with {:ok, storage_record, _event_record} <-
             append_event_record(state, storage, :session_closed, session.id, %{action: :close}) do
        {:ok, storage_record}
      end
    end
  end

  defp maybe_publish(session_id, event_type, payload) do
    event = %{session_id: session_id, type: event_type, payload: payload}

    Bus.record(event, SessionBusPath.events(session_id))

    :ok
  end

  defp append_event_record(state, storage, event_type, session_id, payload) do
    append_event_record(state, storage, event_type, session_id, payload,
      run_id: nil,
      attempt_id: nil,
      parent_run_id: nil,
      role: nil
    )
  end

  defp append_event_record(state, storage, event_type, session_id, payload, opts) do
    run_id = Keyword.get(opts, :run_id)
    attempt_id = Keyword.get(opts, :attempt_id)
    parent_run_id = Keyword.get(opts, :parent_run_id)
    role = Keyword.get(opts, :role)

    with {:ok, event} <-
           Event.new(
             id: generate_id("event"),
             type: event_type,
             session_id: session_id,
             run_id: run_id,
             attempt_id: attempt_id,
             parent_run_id: parent_run_id,
             role: role,
             payload: payload
           ),
         {:ok, storage, event_record} <- state.storage_adapter.append_event(storage, event) do
      maybe_publish(session_id, event_type, payload)
      {:ok, storage, event_record}
    end
  end

  defp session_snapshot_map(envelope) do
    %{
      session: envelope.session,
      runs: envelope.runs,
      attempts: envelope.attempts,
      leases: envelope.leases,
      artifacts: envelope.artifacts,
      verification_results: envelope.verification_results,
      outcomes: envelope.outcomes,
      events: envelope.events
    }
  end

  defp run_snapshot_from_envelope(envelope, run_id) do
    attempts = Enum.filter(envelope.attempts, &(&1.run_id == run_id))
    attempt_ids = MapSet.new(Enum.map(attempts, & &1.id))
    leases = Enum.filter(envelope.leases, &MapSet.member?(attempt_ids, &1.attempt_id))

    artifacts =
      Enum.filter(envelope.artifacts, fn artifact ->
        artifact.run_id == run_id or
          (artifact.attempt_id != nil and MapSet.member?(attempt_ids, artifact.attempt_id))
      end)

    verification_results =
      Enum.filter(envelope.verification_results, &MapSet.member?(attempt_ids, &1.attempt_id))

    outcomes = Enum.filter(envelope.outcomes, &(&1.run_id == run_id))

    events =
      Enum.filter(envelope.events, fn event_record ->
        event_for_run?(event_record.event, run_id, attempt_ids)
      end)

    case Enum.find(envelope.runs, &(&1.id == run_id)) do
      nil ->
        {:error, :not_found}

      run ->
        {:ok,
         %{
           session: envelope.session,
           run: run,
           attempts: attempts,
           leases: leases,
           artifacts: artifacts,
           verification_results: verification_results,
           outcomes: outcomes,
           events: events
         }}
    end
  end

  defp event_for_run?(event, run_id, attempt_ids) do
    event_run_id = event.run_id || event.payload[:run_id]
    event_attempt_id = event.attempt_id || event.payload[:attempt_id]

    event_run_id == run_id or
      (is_binary(event_attempt_id) and MapSet.member?(attempt_ids, event_attempt_id))
  end

  defp ensure_member(ids, value) when is_list(ids) do
    if value in ids do
      {:ok, ids}
    else
      {:ok, ids ++ [value]}
    end
  end

  defp build_submit_run(session_id, task, opts) do
    Run.new(
      id: Keyword.get(opts, :run_id, generate_id("run")),
      session_id: session_id,
      task: task,
      task_pack: Keyword.get(opts, :task_pack, :coding),
      status: Keyword.get(opts, :run_status, :queued),
      parent_run_id: Keyword.get(opts, :parent_run_id),
      role: Keyword.get(opts, :role)
    )
  end

  defp build_submit_attempt(run_id, task_pack, opts) do
    attempt_metadata =
      Map.merge(
        default_attempt_metadata(task_pack, opts),
        Keyword.get(opts, :attempt_metadata, %{})
      )

    Attempt.new(
      id: Keyword.get(opts, :attempt_id, generate_id("attempt")),
      run_id: run_id,
      attempt_number: Keyword.get(opts, :attempt_number, 1),
      status: Keyword.get(opts, :attempt_status, :pending),
      metadata: attempt_metadata
    )
  end

  defp default_attempt_metadata(task_pack, opts) do
    %{
      source: :submit,
      execution_adapter: Keyword.get(opts, :execution_adapter, @default_execution_adapter),
      verification_adapter: build_verifier_adapter(task_pack, opts),
      attempt_number: Keyword.get(opts, :attempt_number, 1)
    }
  end

  defp build_submit_lease(%Session{} = session, %Run{} = run, %Attempt{} = attempt, opts) do
    workspace_root = session.workspace_path || System.tmp_dir!()
    workspace_suffix = Keyword.get(opts, :workspace_suffix, "attempt")

    lease_metadata =
      Map.merge(
        %{
          source_workspace_path: workspace_root,
          run_id: run.id,
          attempt_number: attempt.attempt_number
        },
        Keyword.get(opts, :lease_metadata, %{})
      )

    EnvironmentLease.new(
      id: Keyword.get(opts, :lease_id, generate_id("lease")),
      attempt_id: attempt.id,
      status: :active,
      mode: :exclusive,
      workspace_path:
        Path.join([
          workspace_root,
          ".jidoka",
          "runs",
          run.id,
          "#{workspace_suffix}-#{attempt.id}"
        ]),
      metadata: lease_metadata
    )
  end

  defp append_run_submitted_event(state, session_id, run, attempt) do
    with {:ok, storage_record, _event_record} <-
           append_event_record(
             state,
             state.storage,
             :run_submitted,
             session_id,
             %{
               run_id: run.id,
               attempt_id: attempt.id,
               parent_run_id: run.parent_run_id,
               role: run.role,
               task_pack: run.task_pack
             },
             run_id: run.id,
             parent_run_id: run.parent_run_id,
             role: run.role,
             attempt_id: attempt.id
           ) do
      {:ok, %{state | storage: storage_record}}
    end
  end

  defp build_verifier_adapter(%Run{task_pack: task_pack}, opts) do
    build_verifier_adapter(task_pack, opts)
  end

  defp build_verifier_adapter(task_pack, opts) do
    Keyword.get(opts, :verification_adapter) || default_verification_adapter(task_pack)
  end

  defp execution_adapter_for_attempt(%Attempt{} = attempt, opts) do
    from_opts = Keyword.get(opts, :execution_adapter)
    from_metadata = Map.get(attempt.metadata, :execution_adapter, @default_execution_adapter)
    attempt_metadata = Map.get(attempt.metadata, "execution_adapter", @default_execution_adapter)

    cond do
      is_atom(from_opts) -> from_opts
      is_atom(from_metadata) -> from_metadata
      is_atom(attempt_metadata) -> attempt_metadata
      true -> @default_execution_adapter
    end
  end

  defp verifier_adapter_for_attempt(%Attempt{} = attempt, %Run{} = run, opts) do
    from_opts = Keyword.get(opts, :verification_adapter)
    from_metadata = Map.get(attempt.metadata, :verification_adapter)
    attempt_metadata = Map.get(attempt.metadata, "verification_adapter")

    cond do
      is_atom(from_opts) -> from_opts
      is_atom(from_metadata) -> from_metadata
      is_atom(attempt_metadata) -> attempt_metadata
      true -> build_verifier_adapter(run.task_pack, opts)
    end
  end

  defp persist_attempt_artifacts(state, attempt_id, artifact_specs)
       when is_list(artifact_specs) do
    with {:ok, attempt} <- state.storage_adapter.load_attempt(state.storage, attempt_id),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         {:ok, prepared_artifacts} <- prepare_artifact_records(attempt, run, artifact_specs),
         {:ok, state} <- persist_attempt_artifact_records(state, prepared_artifacts),
         {:ok, state} <-
           reconcile_attempt_artifact_references(state, attempt, run, prepared_artifacts) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_attempt_artifacts}
    end
  end

  defp persist_attempt_artifacts(_state, _attempt_id, _artifact_specs),
    do: {:error, :invalid_artifact_payload}

  defp reconcile_attempt_artifact_references(state, attempt, run, new_artifacts) do
    with {:ok, run_artifacts} <-
           state.storage_adapter.list_artifacts_for_run(state.storage, run.id) do
      attempt_artifacts = Enum.filter(run_artifacts, &(&1.attempt_id == attempt.id))
      all_attempt_artifacts = attempt_artifacts ++ new_artifacts

      {kept_artifacts, archive_candidates} = retain_core_artifacts(all_attempt_artifacts)
      retained_ids = Enum.map(kept_artifacts, & &1.id)

      with {:ok, state} <- archive_artifacts(state, archive_candidates),
           updated_attempt <- %{attempt | artifact_ids: retained_ids},
           {:ok, state} <- persist_attempt_record(state, updated_attempt),
           {:ok, state} <-
             append_attempt_artifact_event(state, run, updated_attempt, new_artifacts) do
        {:ok, state}
      end
    end
  end

  defp persist_attempt_artifact_records(state, artifacts) do
    Enum.reduce_while(artifacts, {:ok, state}, fn artifact, {:ok, acc_state} ->
      with {:ok, storage} <-
             acc_state.storage_adapter.save_artifact(acc_state.storage, artifact) do
        {:cont, {:ok, %{acc_state | storage: storage}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc_state} -> {:ok, acc_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_attempt_artifact_event(state, run, attempt, new_artifacts) do
    if Enum.empty?(new_artifacts) do
      {:ok, state}
    else
      payload =
        %{
          run_id: run.id,
          attempt_id: attempt.id,
          parent_run_id: run.parent_run_id,
          role: run.role,
          artifact_ids: Enum.map(new_artifacts, & &1.id),
          attempt_artifact_ids: attempt.artifact_ids
        }

      append_event_record(
        state,
        state.storage,
        :artifact_emitted,
        run.session_id,
        payload,
        run_id: run.id,
        parent_run_id: run.parent_run_id,
        role: run.role,
        attempt_id: attempt.id
      )
      |> case do
        {:ok, storage, _event_record} -> {:ok, %{state | storage: storage}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp prepare_artifact_records(attempt, run, specs) do
    Enum.reduce_while(
      specs,
      {:ok, []},
      fn
        spec, {:ok, acc} ->
          case normalize_artifact_spec(attempt, run, spec) do
            {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    )
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_artifact_spec(attempt, run, spec) when is_binary(spec) do
    normalize_artifact_spec(attempt, run, %{location: spec})
  end

  defp normalize_artifact_spec(
         %Attempt{} = attempt,
         %Run{} = run,
         %{} = spec
       ) do
    type = Map.get(spec, :type, :transcript)
    metadata = Map.get(spec, :metadata, %{})
    status = Map.get(spec, :status, :ready)

    artifact_inputs =
      Map.merge(
        %{
          id: Map.get(spec, :id, generate_id("artifact")),
          run_id: run.id,
          attempt_id: attempt.id,
          type: type,
          status: status,
          location: Map.get(spec, :location),
          metadata: metadata
        },
        Map.take(spec, [
          :id,
          :run_id,
          :type,
          :status,
          :location,
          :metadata,
          :created_at,
          :updated_at
        ])
      )

    with :ok <- validate_artifact_type(type),
         {:ok, artifact} <- Artifact.new(artifact_inputs),
         :ok <- ensure_artifact_run_match(artifact.run_id, run.id) do
      {:ok, artifact}
    end
  end

  defp normalize_artifact_spec(_attempt, _run, _spec), do: {:error, :invalid_artifact_spec}

  defp ensure_artifact_run_match(spec_run_id, run_id) when spec_run_id == run_id, do: :ok

  defp ensure_artifact_run_match(spec_run_id, run_id),
    do: {:error, {:artifact_run_mismatch, spec_run_id, run_id}}

  defp validate_artifact_type(type) do
    if type in @core_artifact_types do
      :ok
    else
      {:error, {:invalid_artifact_type, @core_artifact_types, type}}
    end
  end

  defp retain_core_artifacts(artifacts) do
    @core_artifact_types
    |> Enum.reduce({[], []}, fn type, {kept, archived} ->
      typed_artifacts = Enum.filter(artifacts, &(&1.type == type))

      case choose_latest_artifact(typed_artifacts) do
        {:ok, selected} ->
          remaining = Enum.reject(typed_artifacts, &(&1.id == selected.id))
          {[selected | kept], archived ++ remaining}

        :none ->
          {kept, archived}
      end
    end)
    |> then(fn {kept, archived} -> {Enum.reverse(kept), archived} end)
  end

  defp archive_artifacts(state, []), do: {:ok, state}

  defp archive_artifacts(state, artifacts) do
    Enum.reduce_while(artifacts, {:ok, state}, fn artifact, {:ok, acc_state} ->
      archived_artifact = %{artifact | status: :archived, updated_at: now()}

      with {:ok, storage} <-
             acc_state.storage_adapter.save_artifact(acc_state.storage, archived_artifact) do
        {:cont, {:ok, %{acc_state | storage: storage}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc_state} -> {:ok, acc_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp choose_latest_artifact([]), do: :none

  defp choose_latest_artifact([artifact]), do: {:ok, artifact}

  defp choose_latest_artifact([a, b | rest]) do
    selected = choose_newer_artifact(a, b)
    choose_latest_artifact([selected | rest])
  end

  defp choose_newer_artifact(a, b) do
    case DateTime.compare(a.created_at, b.created_at) do
      :gt -> a
      :lt -> b
      :eq -> b
    end
  end

  defp default_verification_adapter(:coding), do: @default_verification_adapter
  defp default_verification_adapter("coding"), do: @default_verification_adapter
  defp default_verification_adapter(_), do: @default_verification_adapter

  defp persist_verification_completed(
         state,
         attempt_id,
         %VerificationResult{} = verification_result
       ) do
    with {:ok, attempt} <- state.storage_adapter.load_attempt(state.storage, attempt_id),
         {:ok, run} <- state.storage_adapter.load_run(state.storage, attempt.run_id),
         {:ok, state} <- persist_verification_result_record(state, verification_result),
         updated_attempt <-
           %{attempt | verification_result_id: verification_result.id},
         {:ok, state} <- persist_attempt_record(state, updated_attempt),
         {:ok, updated_run} <- transition_run_for_verification(run, verification_result),
         {:ok, state} <- persist_run_record(state, updated_run),
         {:ok, storage, _event_record} <-
           append_event_record(
             state,
             state.storage,
             :verification_completed,
             run.session_id,
             %{
               run_id: run.id,
               attempt_id: attempt.id,
               verification_result_id: verification_result.id,
               verification_status: verification_result.status
             },
             run_id: run.id,
             attempt_id: attempt.id
           ) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp persist_verification_result_record(state, %VerificationResult{} = verification_result) do
    with {:ok, storage} <-
           state.storage_adapter.save_verification_result(state.storage, verification_result) do
      {:ok, %{state | storage: storage}}
    end
  end

  defp transition_run_for_verification(run, %VerificationResult{status: :passed}) do
    with :ok <- validate_run_transition(run.status, :awaiting_approval) do
      {:ok, %{run | status: :awaiting_approval, outcome: nil, updated_at: now()}}
    end
  end

  defp transition_run_for_verification(run, %VerificationResult{status: :retryable_failed}) do
    with :ok <- validate_run_transition(run.status, :failed) do
      {:ok, %{run | status: :failed, outcome: :retryable_failed, updated_at: now()}}
    end
  end

  defp transition_run_for_verification(run, %VerificationResult{status: :terminal_failed}) do
    with :ok <- validate_run_transition(run.status, :failed) do
      {:ok, %{run | status: :failed, outcome: :terminal_failed, updated_at: now()}}
    end
  end

  defp now do
    Durable.now()
  end

  defp generate_id(prefix) when is_binary(prefix) do
    "#{prefix}-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
