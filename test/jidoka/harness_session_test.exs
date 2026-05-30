defmodule Jidoka.HarnessSessionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

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
