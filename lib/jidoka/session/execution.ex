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
  alias Jidoka.Session.LeaseHeartbeat
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Lineage
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Store
  alias Jidoka.Session.Transitions
  alias Jidoka.Memory
  alias Jidoka.Snapshot
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Limits
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
  def run_sequence(session_input, request_inputs, opts \\ [])

  def run_sequence(session_input, [_request | _rest] = request_inputs, opts)
      when is_list(request_inputs) and is_list(opts) do
    EnvironmentRuntime.with_manager(opts, fn runtime_opts ->
      run_sequence_with_runtime(session_input, request_inputs, runtime_opts)
    end)
  end

  def run_sequence(_session_input, [], opts) when is_list(opts),
    do: {:error, :empty_session_sequence}

  def run_sequence(_session_input, request_inputs, opts) when is_list(opts),
    do: {:error, {:invalid_session_sequence, request_inputs}}

  defp run_sequence_with_runtime(session_input, request_inputs, opts) do
    with :ok <- validate_store_mode(opts),
         {:ok, session} <- resolve_session(session_input, opts),
         {:ok, plan} <- TurnExecution.plan(session.spec),
         {:ok, limits} <- Limits.resolve(plan, opts) do
      opts =
        opts
        |> Keyword.put(:runtime_limits, limits)
        |> Keyword.put(:runtime_sequence_started_at_ms, runtime_clock_ms(opts))

      Jidoka.Extension.RuntimeEvents.emit(
        "session.start",
        %{session_ref: session.session_id, data: %{request_count: length(request_inputs)}},
        opts
      )

      with_sequence_environment_observer(session, opts, fn runtime_opts ->
        state = %{
          session: session,
          steps: [],
          operation_count: sequence_operation_count(session, opts),
          request_ids: []
        }

        result =
          request_inputs
          |> run_sequence_steps(state, 1, runtime_opts)
          |> put_sequence_limits(limits, runtime_opts)

        Jidoka.Extension.RuntimeEvents.emit(
          "session.end",
          %{session_ref: session.session_id, data: %{status: result.status}},
          opts
        )

        result
      end)
    end
  end

  defp with_sequence_environment_observer(session, opts, run) do
    {:ok, tracker} = Elixir.Agent.start_link(fn -> session.environment end)
    observer = fn environment -> Elixir.Agent.update(tracker, fn _current -> environment end) end
    runtime_opts = Keyword.put(opts, :session_environment_observer, observer)

    try do
      result = run.(runtime_opts)

      case Elixir.Agent.get(tracker, & &1) do
        nil -> {:ok, result}
        environment -> {:ok, put_sequence_environment(result, environment)}
      end
    after
      Elixir.Agent.stop(tracker)
    end
  end

  defp put_sequence_environment(%Sequence.Result{} = result, environment) do
    %{result | session: Session.put_environment(result.session, environment)}
  end

  @doc false
  @spec resolve_sequence_session(session_input(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def resolve_sequence_session(session_input, opts) when is_list(opts) do
    resolve_session(session_input, opts)
  end

  @doc false
  @spec persist_sequence_cancellation(map(), Cancellation.t(), runtime_opts()) ::
          {:ok, Session.t()} | {:error, term()}
  def persist_sequence_cancellation(progress, %Cancellation{} = cancellation, opts)
      when is_map(progress) and is_list(opts) do
    with {:ok, session} <- cancellation_session(progress, opts) do
      cancelled =
        session
        |> maybe_put_sequence_request(Map.get(progress, :request))
        |> Session.put_cancellation(cancellation)

      persist_sequence_cancellation_session(cancelled, opts)
    end
  end

  @doc """
  Resumes the latest snapshot for a session.
  """
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []) do
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

  Recovery atomically replaces the expired lease and resumes the latest
  durable snapshot. A completed journal result is replayed. An incomplete
  effect follows its declared idempotency or reconciliation policy.
  """
  @spec recover_session(String.t(), runtime_opts()) :: session_run_result()
  def recover_session(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    opts = Keyword.put(opts, :session_id, session_id)

    with :ok <- validate_store_mode(opts),
         {:ok, store} <- fetch_store(opts),
         {:ok, session} <- Store.recover_session(store, session_id, lease_store_opts(opts)),
         {:ok, session} <- EnvironmentRuntime.restore(session, opts) do
      with_session_environment(session, opts, fn environment_session, environment_opts ->
        recover_claimed_session(environment_session, environment_opts)
      end)
    end
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
         {:ok, source} <- resolve_session(session_input, opts),
         :ok <- ensure_forkable_session(source),
         {:ok, source_snapshot} <- select_fork_snapshot(source, Keyword.get(opts, :snapshot, :latest)),
         {:ok, lineage} <-
           Lineage.next(
             source.lineage,
             source.session_id,
             source_snapshot.snapshot_id,
             clock_ms(opts)
           ),
         {:ok, environment} <- EnvironmentRuntime.fork(source, opts),
         {:ok, fork_snapshot} <-
           fork_snapshot(source_snapshot, source, lineage, environment, opts),
         {:ok, fork} <- Session.fork(source, fork_snapshot, lineage, fork_session_opts(opts)),
         :ok <- ensure_fork_destination_available(fork, opts) do
      persist_session(fork, opts)
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
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
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

  defp run_sequence_steps([], state, _index, _opts) do
    Sequence.Result.new!(
      status: :completed,
      session: state.session,
      steps: state.steps,
      terminal: nil
    )
  end

  defp run_sequence_steps([input | rest], state, index, opts) do
    with {:ok, request} <- normalize_sequence_request(input, opts),
         :ok <- ensure_unique_sequence_request(request, state.request_ids, index) do
      notify_sequence_progress(state, index, request, opts)

      case Limits.check_sequence_deadline(opts, index) do
        :ok ->
          run_sequence_after_deadline(state, request, rest, index, opts)

        {:error, exceeded} ->
          sequence_run_error(state, request, {:runtime_limit_exceeded, exceeded}, index, opts)
      end
    else
      {:error, reason} ->
        terminal_sequence_result(
          :error,
          state.session,
          state.steps,
          index,
          sequence_request_id(input),
          nil,
          reason
        )
    end
  end

  defp run_sequence_after_deadline(state, request, rest, index, opts) do
    case Cancellation.check(opts) do
      :ok -> run_sequence_request(state, request, rest, index, opts)
      {:error, reason} -> sequence_run_error(state, request, reason, index, opts)
    end
  end

  defp run_sequence_request(state, request, rest, index, opts) do
    run_opts =
      opts
      |> Keyword.put(:session_sequence_active, true)
      |> Keyword.put(:session_sequence_terminal, rest == [])
      |> Keyword.put(:fresh_conversation, index == 1 and Keyword.get(opts, :fresh_conversation, false))

    case run_session(sequence_session_input(state.session, opts), request, run_opts) do
      {:ok, session, %Turn.Result{} = result} ->
        operation_results =
          Enum.drop(result.agent_state.operation_results, state.operation_count)

        step =
          Sequence.Step.new!(
            index: index,
            request: request,
            result: result,
            operation_results: operation_results
          )

        next_state = %{
          session: session,
          steps: state.steps ++ [step],
          operation_count: length(result.agent_state.operation_results),
          request_ids: [request.request_id | state.request_ids]
        }

        check =
          if rest == [] do
            Limits.check_usage(next_state.steps, Keyword.fetch!(opts, :runtime_limits), index)
          else
            Limits.check_usage_before_next(
              next_state.steps,
              Keyword.fetch!(opts, :runtime_limits),
              index
            )
          end

        case check do
          :ok ->
            run_sequence_steps(rest, next_state, index + 1, opts)

          {:error, exceeded} ->
            sequence_run_error(
              next_state,
              request,
              {:runtime_limit_exceeded, exceeded},
              index,
              opts
            )
        end

      {:hibernate, session, %Snapshot{} = snapshot} ->
        terminal_sequence_result(
          :hibernated,
          session,
          state.steps,
          index,
          request.request_id,
          snapshot,
          nil
        )

      {:error, reason} ->
        sequence_run_error(state, request, reason, index, opts)
    end
  end

  defp notify_sequence_progress(state, index, request, opts) do
    case Keyword.get(opts, :sequence_progress) do
      callback when is_function(callback, 1) ->
        _result =
          safe_sequence_progress(callback, %{session: state.session, steps: state.steps, index: index, request: request})

        :ok

      _callback ->
        :ok
    end
  end

  defp safe_sequence_progress(callback, progress) do
    callback.(progress)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp normalize_sequence_request(input, opts) do
    Turn.Request.from_input(input, Keyword.take(opts, [:id_generator]))
  end

  defp sequence_run_error(state, request, reason, index, opts) do
    status = if Cancellation.cancelled_reason?(reason), do: :cancelled, else: :error
    session = sequence_error_session(state.session, request, status, reason, opts)

    terminal_sequence_result(
      status,
      session,
      state.steps,
      index,
      request.request_id,
      nil,
      reason
    )
  end

  defp ensure_unique_sequence_request(%Turn.Request{request_id: request_id}, request_ids, index) do
    if request_id in request_ids do
      {:error, {:duplicate_sequence_request_id, index, request_id}}
    else
      :ok
    end
  end

  defp sequence_session_input(%Session{session_id: session_id} = session, opts) do
    if Keyword.has_key?(opts, :store), do: session_id, else: session
  end

  defp sequence_error_session(session, request, status, reason, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        case Store.get_session(store, session.session_id) do
          {:ok, stored} -> stored
          {:error, _reason} -> put_sequence_error(session, request, status, reason)
        end

      :error ->
        put_sequence_error(session, request, status, reason)
    end
  end

  defp sequence_operation_count(%Session{} = session, opts) do
    if Keyword.get(opts, :fresh_conversation, false),
      do: 0,
      else: length(session.conversation.agent_state.operation_results)
  end

  defp put_sequence_error(session, request, :cancelled, reason) do
    session |> maybe_put_sequence_request(request) |> Session.put_cancellation(reason)
  end

  defp put_sequence_error(session, request, :error, reason) do
    session |> maybe_put_sequence_request(request) |> Session.put_error(reason)
  end

  defp terminal_sequence_result(status, session, steps, index, request_id, snapshot, reason) do
    cancellation = if match?(%Cancellation{}, reason), do: reason, else: nil

    terminal =
      Sequence.Terminal.new!(
        kind: status,
        index: index,
        request_id: request_id,
        reason: reason,
        snapshot: snapshot,
        cancellation: cancellation
      )

    Sequence.Result.new!(status: status, session: session, steps: steps, terminal: terminal)
  end

  defp put_sequence_limits(%Sequence.Result{} = result, limits, opts) do
    reason = if result.terminal, do: result.terminal.reason, else: nil
    evidence = Limits.evidence(limits, result.steps, Limits.sequence_elapsed_ms(opts), reason)
    %{result | limits: evidence}
  end

  defp runtime_clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.monotonic_time(:millisecond)
    end
  end

  defp cancellation_session(%{session: %Session{} = session}, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.get_session(store, session.session_id)
      :error -> {:ok, session}
    end
  end

  defp cancellation_session(_progress, _opts),
    do: {:error, :invalid_sequence_cancellation_progress}

  defp maybe_put_sequence_request(session, %Turn.Request{request_id: request_id} = request) do
    case List.last(session.requests) do
      %Turn.Request{request_id: ^request_id} -> session
      _last -> Session.put_request(session, request)
    end
  end

  defp maybe_put_sequence_request(session, _request), do: session

  defp persist_sequence_cancellation_session(
         %Session{lease: %Lease{lease_id: lease_id}} = session,
         opts
       ) do
    with {:ok, store} <- fetch_store(opts) do
      Store.commit_session(
        store,
        session.session_id,
        lease_id,
        session,
        lease_store_opts(opts)
      )
    end
  end

  defp persist_sequence_cancellation_session(%Session{} = session, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.put_session(store, Session.clear_lease(session))
      :error -> {:ok, Session.clear_lease(session)}
    end
  end

  defp sequence_request_id(%Turn.Request{request_id: request_id}), do: request_id

  defp sequence_request_id(input) do
    input
    |> Jidoka.Schema.normalize_attrs()
    |> sequence_request_id_from_attrs()
  end

  defp sequence_request_id_from_attrs(attrs) when is_map(attrs) do
    case Jidoka.Schema.get_key(attrs, :request_id) do
      request_id when is_binary(request_id) -> request_id
      _request_id -> nil
    end
  end

  defp sequence_request_id_from_attrs(_attrs), do: nil

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
        |> persist_session_result(opts, fn _session -> {:error, reason} end)
    end
  end

  defp persist_session_result(%Session{} = session, opts, callback) do
    with {:ok, session} <- persist_session(session, opts) do
      callback.(session)
    end
  end

  defp persist_completed_session(
         %Session{} = session,
         %Turn.Request{} = request,
         %Turn.Result{} = result,
         opts
       ) do
    with {:ok, session} <- persist_session(session, opts) do
      capture_opts = Keyword.put(opts, :session_id, session.session_id)
      _capture = Memory.Runtime.capture_turn(session.spec, request, result, capture_opts)
      {:ok, session, result}
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
    case Session.latest_snapshot(session) do
      %Snapshot{} = snapshot ->
        resume_recovered_snapshot(session, snapshot, opts)

      nil ->
        restart_recovered_request(session, opts)
    end
  end

  defp resume_recovered_snapshot(session, snapshot, opts) do
    with {:ok, prepared} <- TurnExecution.prepare_resume(snapshot, opts) do
      with_session_lease(session, prepared.opts, fn leased_opts ->
        resume_session_snapshot(session, prepared.snapshot, prepared.capabilities, leased_opts)
      end)
    end
  end

  defp restart_recovered_request(%Session{} = session, opts) do
    with %Turn.Request{} = request <- List.last(session.requests),
         opts = Keyword.put(opts, :session_id, session.session_id),
         {:ok, prepared} <- TurnExecution.prepare(session.spec, request, opts) do
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
    else
      nil -> {:error, {:session_not_recoverable, session.session_id, :missing_request}}
      {:error, _reason} = error -> error
    end
  end

  defp latest_snapshot(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %Snapshot{} = snapshot -> {:ok, snapshot}
      nil -> {:error, {:missing_session_snapshot, session.session_id}}
    end
  end

  defp select_fork_snapshot(%Session{} = session, :latest), do: latest_snapshot(session)

  defp select_fork_snapshot(%Session{} = session, %Snapshot{} = candidate) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == candidate.snapshot_id)) do
      ^candidate -> {:ok, candidate}
      %Snapshot{} -> {:error, {:session_snapshot_mismatch, candidate.snapshot_id}}
      nil -> {:error, {:session_snapshot_not_found, session.session_id, candidate.snapshot_id}}
    end
  end

  defp select_fork_snapshot(%Session{} = session, snapshot_input) when is_binary(snapshot_input) do
    case Enum.find(session.snapshots, &(&1.snapshot_id == snapshot_input)) do
      %Snapshot{} = snapshot ->
        {:ok, snapshot}

      nil ->
        with {:ok, %Snapshot{} = snapshot} <- Snapshot.from_input(snapshot_input) do
          select_fork_snapshot(session, snapshot)
        end
    end
  end

  defp select_fork_snapshot(%Session{} = session, snapshot_input) do
    {:error, {:invalid_session_snapshot_selector, session.session_id, snapshot_input}}
  end

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

  defp ensure_forkable_session(%Session{status: :running, session_id: session_id}) do
    {:error, {:cannot_fork_running_session, session_id}}
  end

  defp ensure_forkable_session(%Session{}), do: :ok

  defp ensure_fork_destination_available(%Session{} = fork, opts) do
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

  defp fork_session_opts(opts),
    do: Keyword.take(opts, [:session_id, :id_generator, :metadata])

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end

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
        {:error, reason}
    end
  end

  defp with_session_environment(%Session{} = session, opts, run) when is_function(run, 2) do
    with {:ok, session, runtime_opts, lease} <- EnvironmentRuntime.acquire(session, opts) do
      result =
        session
        |> run.(runtime_opts)
        |> checkpoint_terminal_environment(runtime_opts)

      terminal = environment_terminal(result, runtime_opts)

      case EnvironmentRuntime.finish(lease, terminal, runtime_opts) do
        {:ok, nil} -> result
        {:ok, environment} -> persist_result_environment(result, environment, runtime_opts)
        {:error, finish_reason} -> combine_environment_finish_error(result, finish_reason)
      end
    end
  end

  defp checkpoint_terminal_environment({:ok, _session, _result} = result, opts) do
    case EnvironmentRuntime.checkpoint(opts) do
      {:ok, _environment} -> result
      {:error, reason} -> {:error, {:execution_environment_checkpoint_failed, reason}}
    end
  end

  defp checkpoint_terminal_environment({:hibernate, _session, _snapshot} = result, opts) do
    case EnvironmentRuntime.checkpoint(opts) do
      {:ok, _environment} -> result
      {:error, reason} -> {:error, {:execution_environment_checkpoint_failed, reason}}
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

  defp persist_result_environment({:error, reason} = result, environment, opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} ->
        with {:ok, session} <- Store.get_session(store, Keyword.fetch!(opts, :session_id)),
             {:ok, _stored} <- Store.put_session(store, Session.put_environment(session, environment)) do
          result
        end

      :error ->
        {:error, reason}
    end
  end

  defp combine_environment_finish_error({:error, reason}, finish_reason),
    do: {:error, {:primary_and_environment_finish_failed, reason, finish_reason}}

  defp combine_environment_finish_error(_result, finish_reason),
    do: {:error, {:execution_environment_finish_failed, finish_reason}}

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
