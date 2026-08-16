defmodule Jidoka.HarnessSessionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Harness
  alias Jidoka.Session.Data, as: Session
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
    def claim_resume(_session_id, _opts), do: {:error, :not_called}
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
