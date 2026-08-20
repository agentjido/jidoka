defmodule Jidoka.Session.Execution do
  @moduledoc """
  Application use cases for durable Jidoka sessions.

  This module owns session creation, claims, leases, checkpoints, persistence,
  recovery, forks, replay, and session memory. Direct turn execution belongs to
  `Jidoka.Turn.Execution`.
  """

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Session.Replay
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.EnvironmentRuntime
  alias Jidoka.Session.Fork
  alias Jidoka.Session.LeaseHeartbeat
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Sequence.Execution, as: SequenceExecution
  alias Jidoka.Session.Store
  alias Jidoka.Session.Transitions
  alias Jidoka.Memory
  alias Jidoka.Snapshot
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.TurnRunner
  alias Jidoka.Turn
  alias Jidoka.Turn.Execution, as: TurnExecution

  @type agent_input :: module() | Agent.Spec.t() | keyword() | map()
  @type plan_input :: module() | Agent.Spec.t() | Turn.Plan.t() | keyword() | map()
  @type request_input ::
          Turn.Request.t() | String.t() | [Jidoka.ContentPart.input()] | keyword() | map()
  @type runtime_opts :: keyword()
  @type session_input :: Session.t() | String.t()

  @type session_run_result ::
          {:ok, Session.t(), Turn.Result.t()}
          | {:hibernate, Session.t(), Snapshot.t()}
          | {:error, term()}

  @type internal_session_run_result ::
          {:ok, Session.t(), Turn.Result.t()}
          | {:hibernate, Session.t(), Snapshot.t()}
          | {:error, Session.t(), term()}
          | {:error, term()}

  @type session_sequence_result ::
          {:ok, Sequence.Result.t()}
          | {:error, term()}

  @doc """
  Starts a persisted or caller-managed session.

  Pass `store: {Jidoka.Session.Store.InMemory, pid: pid}` or another
  `Jidoka.Session.Store` implementation to persist the session immediately.
  """
  @spec start_session(plan_input(), runtime_opts()) :: {:ok, Session.t()} | {:error, term()}
  def start_session(spec_or_plan, opts \\ []) do
    with :ok <- validate_store_mode(opts),
         {:ok, plan} <- TurnExecution.plan(spec_or_plan),
         {:ok, session} <- Session.start(plan.spec, session_opts(opts)),
         {:ok, session} <- EnvironmentRuntime.prepare(session, opts) do
      persist_session(session, opts)
    end
  end

  @doc """
  Runs one turn for a session and persists the resulting state.
  """
  @spec run_session(session_input(), request_input(), runtime_opts()) :: session_run_result()
  def run_session(session_input, request_input, opts \\ []) do
    session_input
    |> run_session_internal(request_input, opts)
    |> public_session_result()
  end

  @doc false
  @spec run_session_internal(session_input(), request_input(), runtime_opts()) ::
          internal_session_run_result()
  def run_session_internal(session_input, request_input, opts \\ []) do
    with :ok <- validate_store_mode(opts),
         {:ok, session} <- resolve_session(session_input, opts),
         :ok <- ensure_runnable_session(session),
         {:ok, session} <- EnvironmentRuntime.prepare(session, opts),
         {:ok, session} <- persist_prepared_environment(session_input, session, opts),
         opts = Keyword.put(opts, :session_id, session.session_id),
         {:ok, request} <- continuation_request(session, request_input, opts),
         {:ok, prepared} <- TurnExecution.prepare(session.spec, request, opts),
         {:ok, session} <- claim_session(session_input, session, prepared.request, prepared.opts) do
      runtime_opts = Keyword.put(prepared.opts, :session_id, session.session_id)

      run_session_in_environment(session, prepared, runtime_opts)
    end
  end

  @doc "Runs a nonempty ordered request sequence in one session."
  @spec run_sequence(session_input(), Sequence.input(), runtime_opts()) :: session_sequence_result()
  def run_sequence(session_input, request_inputs, opts \\ []),
    do: SequenceExecution.run(session_input, request_inputs, opts, &run_session_internal/3)

  @doc false
  @spec resolve_sequence_session(session_input(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def resolve_sequence_session(session_input, opts) when is_list(opts) do
    SequenceExecution.resolve_session(session_input, opts)
  end

  @doc false
  @spec persist_sequence_cancellation(map(), Cancellation.t(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def persist_sequence_cancellation(progress, %Cancellation{} = cancellation, opts)
      when is_map(progress) and is_list(opts) do
    SequenceExecution.persist_cancellation(progress, cancellation, opts)
  end

  @doc """
  Resumes the latest snapshot for a session.
  """
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []) do
    session_input
    |> resume_session_internal(opts)
    |> public_session_result()
  end

  @doc false
  @spec resume_session_internal(session_input(), runtime_opts()) :: internal_session_run_result()
  def resume_session_internal(session_input, opts \\ []) do
    with :ok <- validate_store_mode(opts),
         {:ok, session} <- resolve_session(session_input, opts),
         {:ok, session} <- EnvironmentRuntime.prepare(session, opts),
         {:ok, session} <- persist_prepared_environment(session_input, session, opts),
         {:ok, session} <- claim_resume_session(session, opts),
         {:ok, snapshot} <- latest_snapshot(session),
         {:ok, prepared} <- TurnExecution.prepare_resume(snapshot, opts) do
      resume_session_in_environment(session, prepared)
    end
  end

  @doc """
  Recovers a stored session after its worker lease expires.

  Recovery atomically replaces the expired lease. It resumes only a snapshot
  for the leased request, or it restarts that same request when no matching
  snapshot exists. A completed journal result is replayed. An incomplete effect
  follows its declared idempotency or reconciliation policy.
  """
  @spec recover_session(String.t(), runtime_opts()) :: session_run_result()
  def recover_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    opts = Keyword.put(opts, :session_id, session_id)

    result =
      with :ok <- validate_store_mode(opts),
           {:ok, store} <- fetch_store(opts),
           {:ok, session} <- Store.recover_session(store, session_id, lease_store_opts(opts)),
           {:ok, session} <- EnvironmentRuntime.restore(session, opts) do
        with_session_environment(session, opts, fn environment_session, environment_opts ->
          recover_claimed_session(environment_session, environment_opts)
        end)
      end

    public_session_result(result)
  end

  @doc """
  Creates a new session from a safe snapshot in an existing session.

  The source session is not changed. The fork keeps completed effect evidence,
  gets new session and snapshot identifiers, and records durable lineage.
  Pass `snapshot: :latest`, a snapshot id, a signed snapshot string, or a
  snapshot struct that exactly matches source session data.
  """
  @spec fork_session(session_input(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def fork_session(session_input, opts \\ []) do
    with :ok <- validate_store_mode(opts),
         {:ok, source} <- resolve_session(session_input, opts) do
      Fork.create(source, opts)
    end
  end

  @doc "Lists pending human-review requests from a session or store."
  @spec pending_reviews(Session.t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(%Session{} = session), do: {:ok, Session.pending_reviews(session)}
  def pending_reviews(store), do: Store.pending_reviews(store)

  @doc "Returns a data-only replay view for a session or snapshot."
  @spec replay(Session.t() | Snapshot.t()) :: {:ok, Replay.t()} | {:error, term()}
  def replay(%Session{} = session), do: Replay.from_session(session)
  def replay(%Snapshot{} = snapshot), do: Replay.from_snapshot(snapshot)

  @doc "Writes one memory entry through the configured memory store."
  @spec write_memory(plan_input() | Session.t(), String.t(), runtime_opts()) ::
          {:ok, Memory.WriteResult.t()} | {:error, term()}
  def write_memory(spec_or_session, content, opts \\ [])

  def write_memory(%Session{} = session, content, opts) when is_binary(content) do
    Memory.Runtime.write(
      session.spec,
      content,
      Keyword.put(opts, :session_id, session.session_id)
    )
  end

  def write_memory(spec_or_plan, content, opts) when is_binary(content) do
    with {:ok, plan} <- TurnExecution.plan(spec_or_plan) do
      Memory.Runtime.write(plan.spec, content, opts)
    end
  end

  @doc false
  @spec store_get_session(Store.store(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def store_get_session(store, session_id), do: Store.get_session(store, session_id)

  @doc false
  @spec store_list_sessions(Store.store()) :: {:ok, [Session.t()]} | {:error, term()}
  def store_list_sessions(store), do: Store.list_sessions(store)

  @doc false
  @spec store_list_recoverable(Store.store(), keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  def store_list_recoverable(store, opts \\ []), do: Store.list_recoverable(store, opts)

  defp run_session_turn(
         %Session{} = session,
         %Turn.Plan{} = plan,
         %Turn.Request{} = request,
         %Capabilities{} = capabilities,
         opts
       ) do
    case TurnRunner.run(plan, request, capabilities, opts) do
      {:ok, %Turn.Result{} = result} ->
        session
        |> Session.put_result(result)
        |> persist_completed_session(request, result, opts)

      {:hibernate, %Snapshot{} = snapshot} ->
        session
        |> Session.put_snapshot(snapshot)
        |> persist_session_result(opts, fn session -> {:hibernate, session, snapshot} end)

      {:error, reason} ->
        session
        |> put_session_error(reason)
        |> persist_session_result(opts, fn session -> {:error, session, reason} end)
    end
  end

  defp run_session_in_environment(session, prepared, runtime_opts) do
    with_session_environment(session, runtime_opts, fn environment_session, environment_opts ->
      run_session_with_lease(environment_session, prepared, environment_opts)
    end)
  end

  defp run_session_with_lease(environment_session, prepared, environment_opts) do
    with_session_lease(environment_session, environment_opts, fn leased_opts ->
      run_session_turn(
        environment_session,
        prepared.plan,
        prepared.request,
        prepared.capabilities,
        leased_opts
      )
    end)
  end

  defp resume_session_in_environment(session, prepared) do
    with_session_environment(session, prepared.opts, fn environment_session, environment_opts ->
      resume_session_with_lease(environment_session, prepared, environment_opts)
    end)
  end

  defp resume_session_with_lease(environment_session, prepared, environment_opts) do
    with_session_lease(environment_session, environment_opts, fn leased_opts ->
      resume_session_snapshot(
        environment_session,
        prepared.snapshot,
        prepared.capabilities,
        leased_opts
      )
    end)
  end

  defp resume_session_snapshot(
         %Session{} = session,
         %Snapshot{} = snapshot,
         %Capabilities{} = capabilities,
         opts
       ) do
    case TurnRunner.resume(snapshot, capabilities, opts) do
      {:ok, %Turn.Result{} = result} ->
        request = snapshot.turn_state.request

        session
        |> Session.put_result(result)
        |> persist_completed_session(request, result, opts)

      {:hibernate, %Snapshot{} = snapshot} ->
        session
        |> Session.put_snapshot(snapshot)
        |> persist_session_result(opts, fn session -> {:hibernate, session, snapshot} end)

      {:error, reason} ->
        session
        |> put_session_error(reason)
        |> persist_session_result(opts, fn session -> {:error, session, reason} end)
    end
  end

  defp persist_session_result(%Session{} = session, opts, callback) do
    case persist_session(session, opts) do
      {:ok, session} -> callback.(session)
      {:error, reason} -> {:error, session, reason}
    end
  end

  defp persist_completed_session(
         %Session{} = session,
         %Turn.Request{} = request,
         %Turn.Result{} = result,
         opts
       ) do
    case persist_session(session, opts) do
      {:ok, session} ->
        capture_opts = Keyword.put(opts, :session_id, session.session_id)
        _capture = Memory.Runtime.capture_turn(session.spec, request, result, capture_opts)
        {:ok, session, result}

      {:error, reason} ->
        {:error, session, reason}
    end
  end

  defp put_session_error(%Session{} = session, reason) do
    if Cancellation.cancelled_reason?(reason) do
      Session.put_cancellation(session, reason)
    else
      Session.put_error(session, reason)
    end
  end

  defp persist_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> persist_stored_session(store, session, opts)
      :error -> {:ok, session}
    end
  end

  defp persist_prepared_environment(_session_input, %Session{} = session, opts) do
    persist_session(session, opts)
  end

  defp persist_stored_session(
         store,
         %Session{lease: %Lease{lease_id: lease_id}} = session,
         opts
       ) do
    Store.commit_session(store, session.session_id, lease_id, session, lease_store_opts(opts))
  end

  defp persist_stored_session(store, %Session{} = session, _opts),
    do: Store.put_session(store, session)

  defp claim_session(session_id, _session, %Turn.Request{} = request, opts) when is_binary(session_id) do
    with {:ok, store} <- fetch_store(opts) do
      Store.claim_session(store, session_id, request, lease_store_opts(opts))
    end
  end

  defp claim_session(_session_input, %Session{} = session, %Turn.Request{} = request, opts) do
    with {:ok, claimed} <- Transitions.claim_without_lease(session, request) do
      persist_session(claimed, opts)
    end
  end

  defp continuation_request(%Session{} = session, request_input, opts) do
    with {:ok, request} <- Turn.Request.from_input(request_input, session_request_opts(opts)) do
      Conversation.prepare_request(session.conversation, request, opts)
    end
  end

  defp session_request_opts(opts) do
    opts
    |> Keyword.take([:id_generator, :request_id, :context, :metadata])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolve_session(%Session{} = session, _opts), do: {:ok, session}

  defp resolve_session(session_id, opts) when is_binary(session_id) do
    with {:ok, store} <- fetch_store(opts) do
      Store.get_session(store, session_id)
    end
  end

  defp claim_resume_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.claim_resume(store, session.session_id, lease_store_opts(opts))
      :error -> Transitions.resume_without_lease(session)
    end
  end

  defp recover_claimed_session(%Session{} = session, opts) do
    case Session.recovery_target(session) do
      {:ok, {:resume, %Snapshot{} = snapshot}} ->
        resume_recovered_snapshot(session, snapshot, opts)

      {:ok, {:restart, %Turn.Request{} = request}} ->
        restart_recovered_request(session, request, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp resume_recovered_snapshot(session, snapshot, opts) do
    with {:ok, prepared} <- TurnExecution.prepare_resume(snapshot, opts) do
      with_session_lease(session, prepared.opts, fn leased_opts ->
        resume_session_snapshot(session, prepared.snapshot, prepared.capabilities, leased_opts)
      end)
    end
  end

  defp restart_recovered_request(%Session{} = session, %Turn.Request{} = request, opts) do
    opts = Keyword.put(opts, :session_id, session.session_id)

    case TurnExecution.prepare(session.spec, request, opts) do
      {:ok, prepared} -> run_recovered_request(session, prepared)
      {:error, _reason} = error -> error
    end
  end

  defp run_recovered_request(session, prepared) do
    runtime_opts = Keyword.put(prepared.opts, :session_id, session.session_id)

    with_session_lease(session, runtime_opts, fn leased_opts ->
      run_session_turn(
        session,
        prepared.plan,
        prepared.request,
        prepared.capabilities,
        leased_opts
      )
    end)
  end

  defp latest_snapshot(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %Snapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
    end
  end

  defp ensure_runnable_session(%Session{status: :running, session_id: session_id}) do
    {:error, {:session_already_running, session_id}}
  end

  defp ensure_runnable_session(%Session{}), do: :ok

  defp fetch_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :missing_harness_store}
    end
  end

  defp validate_store_mode(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        case Store.durable_mode(store) do
          {:ok, _mode} -> :ok
          {:error, _reason} = error -> error
        end

      :error ->
        :ok
    end
  end

  defp session_opts(opts), do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp with_session_lease(%Session{} = session, opts, run) when is_function(run, 1) do
    opts = durable_runtime_opts(session, opts)

    case start_lease_heartbeat(session, opts) do
      {:ok, heartbeat} ->
        try do
          run.(opts)
        after
          stop_lease_heartbeat(heartbeat)
        end

      {:error, reason} ->
        {:error, session, reason}
    end
  end

  defp with_session_environment(%Session{} = session, opts, run) when is_function(run, 2) do
    case EnvironmentRuntime.acquire(session, opts) do
      {:ok, session, runtime_opts, lease} ->
        result =
          session
          |> run.(runtime_opts)
          |> checkpoint_terminal_environment(runtime_opts)

        terminal = environment_terminal(result, runtime_opts)

        case EnvironmentRuntime.finish(lease, terminal, runtime_opts) do
          {:ok, nil} ->
            result

          {:ok, environment} ->
            persist_result_environment(result, environment, runtime_opts)

          {:error, environment, finish_reason} ->
            result
            |> persist_result_environment(environment, runtime_opts)
            |> combine_environment_finish_error(finish_reason)
        end

      {:error, reason} ->
        {:error, session, reason}
    end
  end

  defp checkpoint_terminal_environment({:ok, session, _result} = result, opts) do
    case EnvironmentRuntime.checkpoint(opts) do
      {:ok, _environment} -> result
      {:error, reason} -> {:error, session, {:execution_environment_checkpoint_failed, reason}}
    end
  end

  defp checkpoint_terminal_environment({:hibernate, session, _snapshot} = result, opts) do
    case EnvironmentRuntime.checkpoint(opts) do
      {:ok, _environment} -> result
      {:error, reason} -> {:error, session, {:execution_environment_checkpoint_failed, reason}}
    end
  end

  defp checkpoint_terminal_environment(result, _opts), do: result

  defp environment_terminal({:hibernate, _session, _snapshot}, _opts), do: :hibernated

  defp environment_terminal({:ok, _session, _result}, opts) do
    if Keyword.get(opts, :session_sequence_active, false) and
         not Keyword.get(opts, :session_sequence_terminal, false),
       do: :continued,
       else: :completed
  end

  defp environment_terminal({:error, reason}, _opts) do
    if Cancellation.cancelled_reason?(reason), do: :cancelled, else: :error
  end

  defp environment_terminal({:error, _session, reason}, _opts) do
    if Cancellation.cancelled_reason?(reason), do: :cancelled, else: :error
  end

  defp persist_result_environment({:ok, session, result}, environment, opts) do
    session = Session.put_environment(session, environment)
    persist_session_result(session, opts, fn session -> {:ok, session, result} end)
  end

  defp persist_result_environment(
         {:hibernate, session, %Snapshot{} = snapshot},
         environment,
         opts
       ) do
    snapshot =
      Snapshot.new!(%Snapshot{
        snapshot
        | schema_version: Snapshot.schema_version(),
          environment: environment
      })

    session = session |> Session.put_environment(environment) |> Session.put_snapshot(snapshot)
    persist_session_result(session, opts, fn session -> {:hibernate, session, snapshot} end)
  end

  defp persist_result_environment({:error, %Session{} = session, reason}, environment, opts) do
    session = Session.put_environment(session, environment)
    persist_session_result(session, opts, fn session -> {:error, session, reason} end)
  end

  defp persist_result_environment({:error, reason}, environment, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        case Store.get_session(store, Keyword.fetch!(opts, :session_id)) do
          {:ok, session} -> persist_environment_error(session, environment, reason, opts)
          {:error, _reason} = error -> error
        end

      :error ->
        {:error, reason}
    end
  end

  defp persist_environment_error(session, environment, reason, opts) do
    session = Session.put_environment(session, environment)
    persist_session_result(session, opts, fn session -> {:error, session, reason} end)
  end

  defp combine_environment_finish_error({:error, %Session{} = session, reason}, finish_reason),
    do: {:error, session, {:primary_and_environment_finish_failed, reason, finish_reason}}

  defp combine_environment_finish_error({:error, reason}, finish_reason),
    do: {:error, {:primary_and_environment_finish_failed, reason, finish_reason}}

  defp combine_environment_finish_error({:ok, %Session{} = session, _result}, finish_reason),
    do: {:error, session, {:execution_environment_finish_failed, finish_reason}}

  defp combine_environment_finish_error({:hibernate, %Session{} = session, _snapshot}, finish_reason),
    do: {:error, session, {:execution_environment_finish_failed, finish_reason}}

  defp combine_environment_finish_error(_result, finish_reason),
    do: {:error, {:execution_environment_finish_failed, finish_reason}}

  defp public_session_result({:error, %Session{}, reason}), do: {:error, reason}
  defp public_session_result(result), do: result

  defp durable_runtime_opts(
         %Session{lease: %Lease{} = lease} = session,
         opts
       ) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        opts = Keyword.put_new(opts, :cancellation, Cancellation.Token.new())

        checkpoint = fn state, intent, stage ->
          durable_checkpoint(store, session, lease, state, intent, stage, opts)
        end

        Keyword.put(opts, :durable_checkpoint, checkpoint)

      :error ->
        opts
    end
  end

  defp durable_runtime_opts(%Session{}, opts), do: opts

  defp durable_checkpoint(store, session, lease, state, intent, stage, opts) do
    cursor = Turn.Cursor.before_effect(intent)

    with {:ok, environment} <- EnvironmentRuntime.checkpoint(opts),
         {:ok, snapshot} <-
           Snapshot.from_turn_state(state, cursor,
             id_generator: Keyword.get(opts, :id_generator),
             environment: environment,
             metadata: %{"durable_checkpoint" => Atom.to_string(stage)}
           ),
         {:ok, stored} <-
           Store.checkpoint_session(
             store,
             session.session_id,
             lease.lease_id,
             snapshot,
             lease_store_opts(opts)
           ) do
      run_durable_checkpoint_hook(stage, snapshot, stored, opts)
    end
  end

  defp run_durable_checkpoint_hook(stage, snapshot, stored, opts) do
    case Keyword.get(opts, :on_durable_checkpoint) do
      hook when is_function(hook, 3) -> hook.(stage, snapshot, stored)
      _hook -> :ok
    end
  end

  defp start_lease_heartbeat(
         %Session{lease: %Lease{lease_id: lease_id}, session_id: session_id},
         opts
       ) do
    cond do
      not Keyword.has_key?(opts, :store) ->
        {:ok, nil}

      Keyword.get(opts, :lease_heartbeat, true) == false ->
        {:ok, nil}

      true ->
        LeaseHeartbeat.start_link(Keyword.fetch!(opts, :store), session_id, lease_id, opts)
    end
  end

  defp start_lease_heartbeat(%Session{}, _opts), do: {:ok, nil}

  defp stop_lease_heartbeat(nil), do: :ok

  defp stop_lease_heartbeat(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  end

  defp lease_store_opts(opts) do
    Keyword.take(opts, [:clock, :id_generator, :lease_ttl_ms, :owner_id])
  end
end
