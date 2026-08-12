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
  alias Jidoka.Session.LeaseHeartbeat
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Lineage
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Store
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
    with {:ok, plan} <- TurnExecution.plan(spec_or_plan),
         {:ok, session} <- Session.start(plan.spec, session_opts(opts)) do
      persist_session(session, opts)
    end
  end

  @doc """
  Runs one turn for a session and persists the resulting state.
  """
  @spec run_session(session_input(), request_input(), runtime_opts()) :: session_run_result()
  def run_session(session_input, request_input, opts \\ []) do
    with {:ok, session} <- resolve_session(session_input, opts),
         :ok <- ensure_runnable_session(session),
         opts = Keyword.put(opts, :session_id, session.session_id),
         {:ok, prepared} <- TurnExecution.prepare(session.spec, request_input, opts),
         {:ok, session} <- claim_session(session_input, session, prepared.request, prepared.opts) do
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
  end

  @doc "Runs a nonempty ordered request sequence in one session."
  @spec run_sequence(session_input(), Sequence.input(), runtime_opts()) :: session_sequence_result()
  def run_sequence(session_input, request_inputs, opts \\ [])

  def run_sequence(session_input, [_request | _rest] = request_inputs, opts)
      when is_list(request_inputs) and is_list(opts) do
    with {:ok, session} <- resolve_session(session_input, opts) do
      state = %{
        session: session,
        steps: [],
        agent_state: nil,
        operation_count: 0,
        request_ids: []
      }

      {:ok, run_sequence_steps(request_inputs, state, 1, opts)}
    end
  end

  def run_sequence(_session_input, [], opts) when is_list(opts),
    do: {:error, :empty_session_sequence}

  def run_sequence(_session_input, request_inputs, opts) when is_list(opts),
    do: {:error, {:invalid_session_sequence, request_inputs}}

  @doc """
  Resumes the latest snapshot for a session.
  """
  @spec resume_session(session_input(), runtime_opts()) :: session_run_result()
  def resume_session(session_input, opts \\ []) do
    with {:ok, session} <- resolve_session(session_input, opts),
         {:ok, session} <- claim_resume_session(session, opts),
         {:ok, snapshot} <- latest_snapshot(session),
         {:ok, prepared} <- TurnExecution.prepare_resume(snapshot, opts) do
      with_session_lease(session, prepared.opts, fn leased_opts ->
        resume_session_snapshot(session, prepared.snapshot, prepared.capabilities, leased_opts)
      end)
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
    with {:ok, store} <- fetch_store(opts),
         {:ok, session} <- Store.recover_session(store, session_id, lease_store_opts(opts)) do
      recover_claimed_session(session, opts)
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
    with {:ok, source} <- resolve_session(session_input, opts),
         :ok <- ensure_forkable_session(source),
         {:ok, source_snapshot} <- select_fork_snapshot(source, Keyword.get(opts, :snapshot, :latest)),
         {:ok, lineage} <-
           Lineage.next(
             source.lineage,
             source.session_id,
             source_snapshot.snapshot_id,
             clock_ms(opts)
           ),
         {:ok, fork_snapshot} <- fork_snapshot(source_snapshot, source, lineage, opts),
         {:ok, fork} <- Session.fork(source, fork_snapshot, lineage, fork_session_opts(opts)),
         :ok <- ensure_fork_destination_available(fork, opts) do
      persist_session(fork, opts)
    end
  end

  @doc "Lists pending human-review requests from a session or store."
  @spec pending_reviews(Session.t() | Store.store()) ::
          {:ok, [Jidoka.Review.Request.t()]} | {:error, term()}
  def pending_reviews(%Session{} = session), do: {:ok, session.pending_reviews}
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
        _capture = Memory.Runtime.capture_turn(plan.spec, request, result, opts)

        session
        |> Session.put_result(result)
        |> persist_session_result(opts, fn session -> {:ok, session, result} end)

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

  defp run_sequence_steps([], state, _index, _opts) do
    Sequence.Result.new!(
      status: :completed,
      session: state.session,
      steps: state.steps,
      terminal: nil
    )
  end

  defp run_sequence_steps([input | rest], state, index, opts) do
    with :ok <- reject_continuation_state(input, index),
         {:ok, request} <- normalize_sequence_request(input, opts),
         :ok <- ensure_unique_sequence_request(request, state.request_ids, index) do
      request = carry_sequence_state(request, state.agent_state)

      case run_session(sequence_session_input(state.session, opts), request, opts) do
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
            agent_state: result.agent_state,
            operation_count: length(result.agent_state.operation_results),
            request_ids: [request.request_id | state.request_ids]
          }

          run_sequence_steps(rest, next_state, index + 1, opts)

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

  defp reject_continuation_state(_input, 1), do: :ok

  defp reject_continuation_state(%Turn.Request{agent_state: agent_state} = request, index) do
    if agent_state == Agent.State.new!() do
      :ok
    else
      {:error, {:sequence_continuation_state_forbidden, index, request.request_id}}
    end
  end

  defp reject_continuation_state(input, index) do
    attrs = Jidoka.Schema.normalize_attrs(input)

    if is_map(attrs) and
         (Map.has_key?(attrs, :agent_state) or Map.has_key?(attrs, "agent_state")) do
      {:error, {:sequence_continuation_state_forbidden, index, sequence_request_id(input)}}
    else
      :ok
    end
  end

  defp ensure_unique_sequence_request(%Turn.Request{request_id: request_id}, request_ids, index) do
    if request_id in request_ids do
      {:error, {:duplicate_sequence_request_id, index, request_id}}
    else
      :ok
    end
  end

  defp carry_sequence_state(%Turn.Request{} = request, nil), do: request

  defp carry_sequence_state(%Turn.Request{} = request, %Agent.State{} = agent_state) do
    %Turn.Request{request | agent_state: agent_state}
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

  defp put_sequence_error(session, request, :cancelled, reason) do
    session |> Session.put_request(request) |> Session.put_cancellation(reason)
  end

  defp put_sequence_error(session, request, :error, reason) do
    session |> Session.put_request(request) |> Session.put_error(reason)
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
        session
        |> Session.put_result(result)
        |> persist_session_result(opts, fn session -> {:ok, session, result} end)

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
    session
    |> Session.put_request(request)
    |> persist_session(opts)
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
      :error -> ensure_resumable_session(session)
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

  defp ensure_resumable_session(%Session{status: status} = session)
       when status in [:hibernated, :waiting],
       do: {:ok, session}

  defp ensure_resumable_session(%Session{session_id: session_id, status: status}),
    do: {:error, {:session_not_resumable, session_id, status}}

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

  defp fork_snapshot(%Snapshot{} = snapshot, %Session{} = source, lineage, opts) do
    fork_opts =
      [
        snapshot_id: Keyword.get(opts, :fork_snapshot_id),
        id_generator: Keyword.get(opts, :id_generator),
        parent_session_id: source.session_id,
        root_session_id: lineage.root_session_id
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Snapshot.fork(snapshot, fork_opts)
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

    with {:ok, snapshot} <-
           Snapshot.from_turn_state(state, cursor,
             id_generator: Keyword.get(opts, :id_generator),
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
