defmodule Jidoka.HarnessSessionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
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
              status: :running,
              requests: [%Turn.Request{request_id: "turn_claim_1"}]
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

  test "sessions collect snapshots and pending review requests" do
    session = Session.start(spec(), session_id: "sess_review") |> elem(1)
    interrupt = interrupt()

    state =
      base_state()
      |> Turn.State.put_pending_interrupt(interrupt)

    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.review(interrupt))
    session = Session.put_snapshot(session, snapshot)

    assert session.status == :waiting

    assert [
             %Review.Request{
               interrupt_id: interrupt_id,
               operation: "refund_order",
               reason: :approval_required
             }
           ] = session.pending_reviews

    assert interrupt_id == interrupt.id
  end

  test "replay projects session snapshots without calling runtime capabilities" do
    session = Session.start(spec(), session_id: "sess_replay") |> elem(1)
    snapshot = AgentSnapshot.from_turn_state!(base_state(), Turn.Cursor.after_prompt())
    session = Session.put_snapshot(session, snapshot)

    assert {:ok,
            %Harness.Replay{
              session_id: "sess_replay",
              agent_id: "harness_session_agent",
              status: :hibernated,
              snapshots: [%{snapshot_id: _snapshot_id, cursor: %{phase: :after_prompt}}],
              journal: %{intents: [], results: []}
            }} = Harness.replay(session)
  end

  defp spec do
    Agent.Spec.new!(
      id: "harness_session_agent",
      instructions: "Test harness sessions.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp base_state do
    spec = spec()
    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

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
