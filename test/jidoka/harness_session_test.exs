defmodule Jidoka.HarnessSessionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Harness
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.Execution
  alias Jidoka.Session.Lineage
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Store
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Review
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  defmodule FallbackStore do
    @moduledoc false

    @behaviour Store

    def start_link do
      Elixir.Agent.start_link(fn -> %{} end)
    end

    @impl true
    def put_session(%Session{} = session, opts) do
      pid = Keyword.fetch!(opts, :pid)
      Elixir.Agent.update(pid, &Map.put(&1, session.session_id, session))
      {:ok, session}
    end

    @impl true
    def get_session(session_id, opts) do
      pid = Keyword.fetch!(opts, :pid)

      case Elixir.Agent.get(pid, &Map.get(&1, session_id)) do
        %Session{} = session -> {:ok, session}
        nil -> {:error, {:session_not_found, session_id}}
      end
    end

    @impl true
    def list_sessions(opts) do
      pid = Keyword.fetch!(opts, :pid)
      {:ok, Elixir.Agent.get(pid, &Map.values/1)}
    end
  end

  defmodule ClaimOnlyStore do
    @behaviour Store

    @impl true
    def put_session(session, opts) do
      send(Keyword.fetch!(opts, :test_pid), :partial_store_called)
      {:ok, session}
    end

    @impl true
    def get_session(_session_id, _opts), do: {:error, :not_called}

    @impl true
    def list_sessions(_opts), do: {:ok, []}

    @impl true
    def claim_session(_session_id, _request, opts) do
      send(Keyword.fetch!(opts, :test_pid), :partial_store_called)
      {:error, :not_called}
    end
  end

  defmodule ResumeOnlyStore do
    def claim_resume(_session_id, opts) do
      if test_pid = Keyword.get(opts, :test_pid), do: send(test_pid, :partial_resume_store_called)
      {:error, :not_called}
    end
  end

  defmodule RecoverOnlyStore do
    def recover_session(_session_id, _opts), do: {:error, :not_called}
  end

  defmodule CheckpointOnlyStore do
    def checkpoint_session(_session_id, _lease_id, _snapshot, _opts), do: {:error, :not_called}
  end

  defmodule CommitOnlyStore do
    def commit_session(_session_id, _lease_id, _session, _opts), do: {:error, :not_called}
  end

  defmodule RenewOnlyStore do
    def renew_session(_session_id, _lease_id, _opts), do: {:error, :not_called}
  end

  test "sessions can be started and persisted in the in-memory store" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    spec = spec()

    assert {:ok, %Session{session_id: "sess_1", status: :new} = session} =
             Harness.start_session(spec, session_id: "sess_1", store: store)

    assert {:ok, ^session} = Harness.store_get_session(store, "sess_1")
    assert {:ok, [%Session{session_id: "sess_1"}]} = Harness.store_list_sessions(store)
    assert {:ok, []} = Harness.pending_reviews(store)
  end

  test "internal failures retain the same session that was persisted" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    reason = :forced_model_failure
    failing_llm = fn _intent, _journal, _context -> {:error, reason} end

    assert {:ok, %Session{}} =
             Harness.start_session(spec(), session_id: "sess_internal_error", store: store)

    assert {:error, %Session{} = failed, %Jidoka.Error.ExecutionError{details: %{cause: ^reason}} = error} =
             Execution.run_session_internal(
               "sess_internal_error",
               "Fail",
               store: store,
               llm: failing_llm
             )

    assert failed.status == :error
    assert failed.error == error
    assert {:ok, ^failed} = Store.get_session(store, "sess_internal_error")

    assert {:ok, %Session{}} =
             Harness.start_session(spec(), session_id: "sess_public_error", store: store)

    assert {:error, %Jidoka.Error.ExecutionError{details: %{cause: ^reason}}} =
             Harness.run_session("sess_public_error", "Fail", store: store, llm: failing_llm)
  end

  test "in-memory stores atomically claim a session before running a turn" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    request = Turn.Request.new!(input: "First turn", request_id: "turn_claim_1")

    assert {:ok, %Session{session_id: "sess_claim"}} =
             Harness.start_session(spec(), session_id: "sess_claim", store: store)

    assert {:ok,
            %Session{
              session_id: "sess_claim",
              revision: 1,
              status: :running,
              requests: [%Turn.Request{request_id: "turn_claim_1"}],
              lease: %Lease{request_id: "turn_claim_1"}
            }} = Store.claim_session(store, "sess_claim", request)

    assert {:error, {:session_already_running, "sess_claim"}} =
             Store.claim_session(store, "sess_claim", Turn.Request.new!(input: "Second turn"))

    assert {:error, {:session_not_found, "missing_claim"}} =
             Store.claim_session(store, "missing_claim", Turn.Request.new!(input: "Missing turn"))

    assert {:ok, %Session{status: :running, requests: [%Turn.Request{input: "First turn"}]}} =
             Harness.store_get_session(store, "sess_claim")
  end

  test "store claim fallback keeps older store implementations compatible" do
    {:ok, pid} = FallbackStore.start_link()
    store = {FallbackStore, pid: pid}
    request = Turn.Request.new!(input: "Fallback turn", request_id: "turn_fallback_1")

    assert {:ok, %Session{session_id: "sess_fallback"} = session} =
             Session.start(spec(), session_id: "sess_fallback")

    assert {:ok, ^session} = Store.put_session(store, session)

    assert {:ok,
            %Session{
              session_id: "sess_fallback",
              status: :running,
              requests: [%Turn.Request{request_id: "turn_fallback_1"}]
            }} = Store.claim_session(store, "sess_fallback", request)

    assert {:error, {:session_already_running, "sess_fallback"}} =
             Store.claim_session(store, "sess_fallback", Turn.Request.new!(input: "Duplicate turn"))
  end

  test "store durable mode is either none or complete" do
    assert {:ok, :none} = Store.durable_mode(FallbackStore)
    assert {:ok, :durable} = Store.durable_mode(InMemory)

    partial_stores = [
      {ClaimOnlyStore, [claim_session: 3]},
      {ResumeOnlyStore, [claim_resume: 2]},
      {RecoverOnlyStore, [recover_session: 2]},
      {CheckpointOnlyStore, [checkpoint_session: 4]},
      {CommitOnlyStore, [commit_session: 4]},
      {RenewOnlyStore, [renew_session: 3]}
    ]

    for {store, implemented} <- partial_stores do
      assert {:error, {:partial_durable_session_store, ^store, ^implemented, missing}} =
               Store.durable_mode(store)

      assert length(missing) == 5
    end
  end

  test "a partial durable store is rejected before startup or claim" do
    store = {ClaimOnlyStore, test_pid: self()}
    request = Turn.Request.new!(input: "Do not claim", request_id: "partial-store-request")

    assert {:error, {:partial_durable_session_store, ClaimOnlyStore, [claim_session: 3], missing}} =
             Harness.start_session(spec(), session_id: "partial-store-session", store: store)

    assert length(missing) == 5
    refute_receive :partial_store_called

    assert {:error, {:partial_durable_session_store, ClaimOnlyStore, [claim_session: 3], _missing}} =
             Store.claim_session(store, "partial-store-session", request)

    refute_receive :partial_store_called

    assert {:error, {:partial_durable_session_store, ResumeOnlyStore, [claim_resume: 2], _missing}} =
             Store.claim_resume({ResumeOnlyStore, test_pid: self()}, "partial-store-session")

    refute_receive :partial_resume_store_called
  end

  test "sessions collect snapshots and pending review requests" do
    session = Session.start(spec(), session_id: "sess_review") |> elem(1)
    interrupt = interrupt()

    state =
      base_state()
      |> Turn.State.put_pending_interrupt(interrupt)

    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.review(interrupt))
    session = Session.put_snapshot(session, snapshot)

    assert session.status == :waiting

    assert [
             %Review.Request{
               interrupt_id: interrupt_id,
               operation: "refund_order",
               reason: :approval_required
             }
           ] = Session.pending_reviews(session)

    assert interrupt_id == interrupt.id
  end

  test "replay projects session snapshots without calling runtime capabilities" do
    session = Session.start(spec(), session_id: "sess_replay") |> elem(1)
    snapshot = Snapshot.from_turn_state!(base_state(), Turn.Cursor.after_prompt())
    session = Session.put_snapshot(session, snapshot)

    assert {:ok,
            %Jidoka.Session.Replay{
              session_id: "sess_replay",
              agent_id: "harness_session_agent",
              status: :hibernated,
              snapshots: [%{snapshot_id: _snapshot_id, cursor: %{phase: :after_prompt}}],
              journal: %{intents: [], results: []}
            }} = Harness.replay(session)
  end

  test "safe forks copy stored snapshot evidence and record durable lineage" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    source = Session.start(spec(), session_id: "sess_source", metadata: %{tenant: "acme"}) |> elem(1)
    request = Turn.Request.new!(input: "Hello", request_id: "turn_source")

    snapshot =
      base_state(request)
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "snap_source")

    source = source |> Session.put_request(request) |> Session.put_snapshot(snapshot)
    assert {:ok, ^source} = Store.put_session(store, source)
    assert {:ok, signed_snapshot} = Snapshot.serialize(snapshot)

    assert {:ok,
            %Session{
              session_id: "sess_fork",
              status: :hibernated,
              requests: [%Turn.Request{request_id: "turn_source"}],
              snapshots: [%Snapshot{snapshot_id: "snap_fork"}],
              lineage: %Lineage{
                root_session_id: "sess_source",
                parent_session_id: "sess_source",
                source_snapshot_id: "snap_source",
                forked_at_ms: 1_234,
                depth: 1
              },
              metadata: %{tenant: "acme", branch: "alternate"}
            } = fork} =
             Harness.fork_session("sess_source",
               store: store,
               session_id: "sess_fork",
               fork_snapshot_id: "snap_fork",
               snapshot: signed_snapshot,
               clock: fn -> 1_234 end,
               metadata: %{branch: "alternate"}
             )

    assert hd(fork.snapshots).turn_state == snapshot.turn_state
    assert hd(fork.snapshots).metadata["fork"]["source_snapshot_id"] == "snap_source"
    assert {:ok, ^source} = Store.get_session(store, "sess_source")
    assert {:ok, ^fork} = Store.get_session(store, "sess_fork")

    assert {:ok, %Jidoka.Session.Replay{lineage: %{parent_session_id: "sess_source", depth: 1}}} =
             Harness.replay(fork)
  end

  test "safe forks reject running sources, changed snapshots, and existing targets" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    source = Session.start(spec(), session_id: "sess_source") |> elem(1)
    snapshot = Snapshot.from_turn_state!(base_state(), Turn.Cursor.after_prompt())
    source = Session.put_snapshot(source, snapshot)
    assert {:ok, ^source} = Store.put_session(store, source)

    changed = %Snapshot{snapshot | metadata: %{"changed" => true}}

    assert {:error, {:session_snapshot_mismatch, snapshot_id}} =
             Harness.fork_session(source, snapshot: changed, session_id: "sess_changed")

    assert snapshot_id == snapshot.snapshot_id

    assert {:ok, %Session{session_id: "sess_existing"}} =
             Harness.start_session(spec(), session_id: "sess_existing", store: store)

    assert {:error, {:fork_session_already_exists, "sess_existing"}} =
             Harness.fork_session(source, session_id: "sess_existing", store: store)

    running = Session.put_request(source, Turn.Request.new!(input: "Active"))

    assert {:error, {:cannot_fork_running_session, "sess_source"}} =
             Harness.fork_session(running, session_id: "sess_running_fork")
  end

  test "nested forks keep the root session and increase lineage depth" do
    source = Session.start(spec(), session_id: "sess_root") |> elem(1)
    snapshot = Snapshot.from_turn_state!(base_state(), Turn.Cursor.after_prompt())
    source = Session.put_snapshot(source, snapshot)

    assert {:ok, first} =
             Harness.fork_session(source,
               session_id: "sess_child",
               fork_snapshot_id: "snap_child",
               clock: fn -> 10 end
             )

    assert {:ok, second} =
             Harness.fork_session(first,
               session_id: "sess_grandchild",
               fork_snapshot_id: "snap_grandchild",
               clock: fn -> 20 end
             )

    assert %Lineage{
             root_session_id: "sess_root",
             parent_session_id: "sess_child",
             source_snapshot_id: "snap_child",
             depth: 2
           } = second.lineage
  end

  test "session execution exposes complete default-arity facade behavior" do
    assert {:ok, %Session{} = started} = Execution.start_session(spec())

    running = Session.put_request(started, Turn.Request.new!(input: "active"))

    assert {:error, {:session_already_running, _session_id}} =
             Execution.run_session(running, "cannot run")

    assert {:error, {:session_already_running, _session_id}} =
             Execution.run_session_internal(running, "cannot run")

    assert {:error, :empty_session_sequence} = Execution.run_sequence(started, [])

    hibernated = %Session{started | status: :hibernated}
    assert {:error, {:missing_session_snapshot, _session_id}} = Execution.resume_session(hibernated)

    assert {:error, {:missing_session_snapshot, _session_id}} =
             Execution.resume_session_internal(hibernated)

    assert {:error, :missing_harness_store} = Execution.recover_session("missing")
    assert {:error, {:missing_session_snapshot, _session_id}} = Execution.fork_session(started)
    assert {:ok, []} = Execution.pending_reviews(started)

    snapshot = Snapshot.from_turn_state!(base_state(), Turn.Cursor.after_prompt())
    assert {:ok, %Jidoka.Session.Replay{snapshots: [_]}} = Execution.replay(snapshot)

    assert {:error, :missing_memory_store} = Execution.write_memory(spec(), "remember")
    assert {:error, :missing_memory_store} = Execution.write_memory(started, "remember")

    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    assert {:ok, ^started} = Store.put_session(store, started)
    assert {:ok, ^started} = Execution.store_get_session(store, started.session_id)
    assert {:ok, [^started]} = Execution.store_list_sessions(store)
    assert {:ok, []} = Execution.store_list_recoverable(store)
    assert {:ok, []} = Execution.pending_reviews(store)
  end

  test "session data rejects unsafe forks and selects strict recovery work" do
    request = Turn.Request.new!(input: "recover", request_id: "turn-recover")
    other = Turn.Request.new!(input: "other", request_id: "turn-other")
    lease = Lease.acquire("turn-recover", 0, 100, id_generator: fn "lease" -> "lease-recover" end) |> elem(1)
    session = Session.start(spec(), session_id: "session-recovery") |> elem(1)

    assert {:error, {:session_not_recoverable, "session-recovery", :missing_lease}} =
             Session.recovery_target(session)

    restartable = session |> Session.put_request(request) |> Session.put_lease(lease)
    assert {:ok, {:restart, ^request}} = Session.recovery_target(restartable)

    missing = Session.put_lease(session, lease)

    assert {:error, {:recovery_request_not_found, "session-recovery", "turn-recover"}} =
             Session.recovery_target(missing)

    duplicate = %Session{restartable | requests: [request, request]}

    assert {:error, {:recovery_request_identity_conflict, "session-recovery", "turn-recover", 2}} =
             Session.recovery_target(duplicate)

    mismatched = %Session{restartable | requests: [request, other]}

    assert {:error, {:recovery_request_mismatch, "session-recovery", "turn-recover", "turn-other"}} =
             Session.recovery_target(mismatched)

    unknown_snapshot =
      Turn.Request.new!(input: "unknown", request_id: "turn-unknown")
      |> base_state()
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "snapshot-unknown")

    with_unknown = %Session{restartable | snapshots: [unknown_snapshot]}

    assert {:error,
            {:recovery_snapshot_request_mismatch, "session-recovery", "snapshot-unknown", "turn-unknown",
             "turn-recover"}} = Session.recovery_target(with_unknown)

    matching_snapshot =
      request
      |> base_state()
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "snapshot-match")

    other_snapshot =
      other
      |> base_state()
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "snapshot-other")

    out_of_order = %Session{
      restartable
      | requests: [other, request],
        snapshots: [matching_snapshot, other_snapshot]
    }

    assert {:error,
            {:recovery_snapshot_order_mismatch, "session-recovery", "turn-recover", "snapshot-match", "snapshot-other"}} =
             Session.recovery_target(out_of_order)
  end

  test "session data normalizes constructors, environment, extensions, and fork identity" do
    generator = fn "sess" -> "session-generated" end
    assert {:ok, %Session{session_id: "session-generated"} = generated} = Session.start(spec(), id_generator: generator)
    assert {:ok, %Session{} = normalized} = Session.from_input(generated)
    assert normalized.session_id == generated.session_id
    assert Session.put_environment(normalized, nil).environment == nil

    assert_raise ArgumentError, ~r/invalid durable session/, fn -> Session.new!(%{}) end

    assert {:error, {:invalid_extension_state, _reason}} =
             Session.put_extension_state(normalized, %{"unsafe" => self()})

    request = Turn.Request.new!(input: "fork", request_id: "turn-fork-contract")

    snapshot =
      request
      |> base_state()
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "snapshot-fork-contract")

    source = normalized |> Session.put_request(request) |> Session.put_snapshot(snapshot)

    lineage =
      Lineage.new!(
        root_session_id: source.session_id,
        parent_session_id: source.session_id,
        source_snapshot_id: snapshot.snapshot_id,
        forked_at_ms: 1,
        depth: 1
      )

    wrong_agent = %Snapshot{snapshot | agent_id: "different-agent"}

    assert {:error, {:snapshot_agent_mismatch, "harness_session_agent", "different-agent"}} =
             Session.fork(source, wrong_agent, lineage, session_id: "fork-target")

    assert {:error, {:fork_session_id_matches_source, "session-generated"}} =
             Session.fork(source, snapshot, lineage, session_id: "session-generated")

    result = Turn.Result.from_turn_state!(%{base_state(request) | status: :finished, result: "done"})

    assert %Session{status: :finished, conversation: %Jidoka.Session.Conversation{}} =
             Session.put_result(%{source | conversation: nil}, result)

    assert %Session{status: :finished, conversation: %Jidoka.Session.Conversation{}} =
             Session.put_result(%{source | requests: []}, result)
  end

  test "the public session facade covers default error and data paths" do
    assert {:ok, %Session{} = session} =
             Jidoka.Session.start(spec(), id_generator: fn "sess" -> "session-facade" end)

    running = Session.put_request(session, Turn.Request.new!(input: "active", request_id: "facade-active"))
    hibernated = %Session{session | status: :hibernated}

    assert {:error, {:session_already_running, "session-facade"}} = Jidoka.Session.run(running, "blocked")
    assert {:error, :empty_session_sequence} = Jidoka.Session.run_sequence(session, [])
    assert {:error, :empty_session_sequence} = Jidoka.Session.run_sequence_async(session, [])
    assert {:error, {:session_already_running, "session-facade"}} = Jidoka.Session.chat(running, "blocked")
    assert {:error, :invalid_async_request} = Jidoka.Session.await(:invalid)
    assert {:error, :invalid_async_request} = Jidoka.Session.cancel(:invalid)
    assert {:error, {:missing_session_snapshot, "session-facade"}} = Jidoka.Session.resume(hibernated)
    assert {:error, {:missing_session_snapshot, "session-facade"}} = Jidoka.Session.fork(session)
    assert {:error, :missing_harness_store} = Jidoka.Session.recover("session-facade")
    assert {:ok, []} = Jidoka.Session.pending_reviews(session)
    assert {:ok, %Jidoka.Session.Replay{session_id: "session-facade"}} = Jidoka.Session.replay(session)
    assert {:error, :missing_memory_store} = Jidoka.Session.write_memory(session, "remember")

    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    assert {:ok, ^session} = Store.put_session(store, session)
    assert {:ok, ^session} = Jidoka.Session.get(store, session.session_id)
    assert {:ok, [^session]} = Jidoka.Session.list(store)
    assert {:ok, []} = Jidoka.Session.recoverable(store)

    assert {:ok, async_request} = Jidoka.Session.chat_async(running, "blocked")
    assert {:error, {:session_already_running, "session-facade"}} = Jidoka.Session.await(async_request)
  end

  test "session store wrappers expose default durable and pure transition paths" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    session = Session.start(spec(), session_id: "store-wrappers") |> elem(1)
    request = Turn.Request.new!(input: "store", request_id: "store-request")

    assert {:error, {:invalid_session_store_module, MissingStore, _reason}} = Store.durable_mode(MissingStore)
    assert {:ok, ^session} = Store.put_transition(nil, session)

    assert {:ok, claimed} =
             Store.claim_transition(session, request,
               clock: fn -> 10 end,
               lease_ttl_ms: 20,
               id_generator: fn "lease" -> "store-lease" end
             )

    assert {:error, {:session_not_resumable, "store-wrappers", :running}} =
             Store.resume_transition(claimed, clock: fn -> 11 end)

    assert {:error, {:session_lease_active, "store-wrappers", _owner, 30}} =
             Store.recover_transition(claimed, clock: fn -> 11 end)

    assert {:ok, renewed} = Store.renew_transition(claimed, "store-lease", clock: fn -> 12 end)
    assert renewed.revision == claimed.revision + 1

    snapshot =
      request
      |> base_state()
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: "store-snapshot")

    assert {:ok, checkpointed} =
             Store.checkpoint_transition(claimed, "store-lease", snapshot, clock: fn -> 12 end)

    assert {:ok, identity} = Store.checkpoint_identity(checkpointed, snapshot)
    assert identity.snapshot_id == "store-snapshot"

    assert {:error, {:checkpoint_identity_mismatch, "store-wrappers", 0, nil, "store-request", "store-snapshot"}} =
             Store.checkpoint_identity(session, snapshot)

    assert {:error, {:session_not_found, "missing"}} = Store.recover_session(store, "missing")
    assert {:error, {:session_not_found, "missing"}} = Store.checkpoint_session(store, "missing", "lease", snapshot)
    assert {:error, {:session_not_found, "missing"}} = Store.commit_session(store, "missing", "lease", session)
    assert {:error, {:session_not_found, "missing"}} = Store.renew_session(store, "missing", "lease")
    assert {:ok, []} = Store.list_recoverable(store, clock: fn -> 20 end)

    {:ok, fallback_pid} = FallbackStore.start_link()
    fallback = {FallbackStore, pid: fallback_pid}

    assert {:error, {:durable_store_capability_missing, FallbackStore, :recover_session}} =
             Store.recover_session(fallback, "missing")
  end

  defp spec do
    Agent.Spec.new!(
      id: "harness_session_agent",
      instructions: "Test harness sessions.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp base_state(request \\ nil) do
    spec = spec()
    plan = Turn.Plan.new!(spec)
    request = request || Turn.Request.new!(input: "Hello")

    Turn.State.new!(
      spec: spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp interrupt do
    Review.Interrupt.new!(
      id: Review.Interrupt.stable_id(["harness_session_agent", "refund_order"]),
      boundary: :operation,
      control: __MODULE__,
      control_name: "approval_control",
      reason: :approval_required,
      agent_id: "harness_session_agent",
      request_id: "turn_1",
      loop_index: 0,
      effect_id: "operation:refund_order",
      effect_kind: :operation,
      operation: "refund_order",
      operation_kind: :operation,
      arguments: %{"order_id" => "order_123"},
      idempotency: :unsafe_once,
      idempotency_key: "key"
    )
  end
end
