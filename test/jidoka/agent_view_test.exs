defmodule Jidoka.AgentViewTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.AgentView
  alias Jidoka.Event
  alias Jidoka.Effect
  alias Jidoka.Turn

  defmodule DemoAgent do
    use Jidoka.Agent

    agent :demo_agent
  end

  defmodule DemoView do
    use Jidoka.AgentView, agent: DemoAgent
  end

  defmodule RuntimeAgent do
    def id, do: "runtime_agent"
  end

  defmodule RuntimeView do
    use Jidoka.AgentView, agent: RuntimeAgent

    @impl true
    def prepare(%{reject?: true}), do: {:error, :rejected}
    def prepare(_input), do: :ok

    @impl true
    def runtime_context(input) do
      %{tenant: Map.get(input, :tenant, "default")}
    end
  end

  defmodule MissingAgentView do
    use Jidoka.AgentView
  end

  test "initial view projects identity without owning runtime state" do
    assert {:ok, %AgentView{} = view} = DemoView.initial(%{conversation_id: "VIP Case!"})

    assert view.agent_id == "demo_agent-vip_case"
    assert view.conversation_id == "vip_case"
    assert view.runtime_context == %{session: "vip_case"}
    assert view.metadata.agent.id == "demo_agent"

    attrs = Map.from_struct(view)
    refute Map.has_key?(attrs, :pid)
    refute Map.has_key?(attrs, :thread)
    refute Map.has_key?(attrs, :transcript)
    refute Map.has_key?(attrs, :storage)
  end

  test "before_turn and after_turn keep visible messages and tool events as projections" do
    {:ok, view} = DemoView.initial(%{conversation_id: "case_123"})

    running = DemoView.before_turn(view, " Check order A1001 ")

    assert running.status == :running

    assert [%{role: :user, content: "Check order A1001", pending?: true}] =
             running.visible_messages

    result =
      Turn.Result.new!(
        content: "Order A1001 is in transit.",
        agent_state:
          Agent.State.new!(
            operation_results: [
              Effect.OperationResult.new!(
                operation: "lookup_order",
                arguments: %{"order_id" => "A1001"},
                output: %{"status" => "in_transit"},
                effect_id: "eff_lookup"
              )
            ]
          ),
        journal: Effect.Journal.new!()
      )

    finished = DemoView.after_turn(running, {:ok, result})

    assert finished.status == :idle

    assert [
             %{role: :user, pending?: false},
             %{role: :assistant, content: "Order A1001 is in transit."}
           ] = finished.visible_messages

    assert [
             %{
               id: "eff_lookup",
               kind: :operation_result,
               label: "tool result: lookup_order",
               refs: %{operation: "lookup_order"}
             }
           ] = finished.events
  end

  test "default helpers normalize ids and expose lifecycle hooks" do
    assert AgentView.default_conversation_id(%{"conversation_id" => "Billing / VIP"}) ==
             "billing_vip"

    assert AgentView.default_conversation_id(%{conversation_id: "!!!"}) == "default"
    assert AgentView.normalize_id(nil, "fallback") == "fallback"
    assert AgentView.request_id() =~ "agent_view_"
    assert AgentView.lifecycle_hooks() == [:before_turn, :after_turn, :snapshot]
  end

  test "streamed events update an in-flight assistant draft and debug activity" do
    {:ok, view} = DemoView.initial(%{conversation_id: "case_123"})
    running = DemoView.before_turn(view, "Need help")

    delta =
      Event.new!(
        event: :llm_delta,
        request_id: "req_agent_view",
        data: %{chunk_type: :content, delta: "Working"}
      )

    updated = DemoView.apply_event(running, delta)

    assert [
             %{role: :user, content: "Need help"},
             %{role: :assistant, content: "Working", streaming?: true}
           ] = DemoView.visible_messages(updated)

    event = Event.build(:effect_started, [], request_id: "req_agent_view", effect_kind: :llm)
    updated = DemoView.apply_event(updated, event)

    assert [%{kind: :effect_started, refs: %{request_id: "req_agent_view"}}] = updated.events
  end

  test "view error, hibernate, empty input, duplicate events, and thinking deltas stay stable" do
    {:ok, view} = RuntimeView.initial(%{conversation_id: "case_456", tenant: "acme"})

    assert view.agent_id == "runtime_agent-case_456"
    assert view.runtime_context == %{tenant: "acme"}

    idle = RuntimeView.before_turn(view, "   ")
    assert idle.status == :idle
    assert idle.visible_messages == []

    errored = RuntimeView.after_turn(view, {:error, :failed})
    assert errored.status == :error
    assert errored.error == :failed
    assert is_binary(errored.error_text)

    snapshot = snapshot()
    interrupted = RuntimeView.after_turn(view, {:hibernate, snapshot})
    assert interrupted.status == :interrupted
    assert interrupted.metadata.last_snapshot.snapshot_id == snapshot.snapshot_id

    thinking =
      Event.new!(
        event: :llm_delta,
        request_id: "req_thinking",
        data: %{chunk_type: :thinking, delta: "Analyzing"}
      )

    updated = RuntimeView.apply_event(view, thinking)

    assert [%{role: :assistant, content: "Thinking...", thinking: "Analyzing"}] =
             RuntimeView.visible_messages(updated)

    event =
      Event.new!(
        event: :effect_started,
        seq: 0,
        request_id: "req_duplicate",
        effect_id: "effect_1",
        effect_kind: :llm
      )

    updated =
      updated
      |> RuntimeView.apply_event(event)
      |> RuntimeView.apply_event(event)
      |> RuntimeView.apply_event(%{ignored: true})

    assert Enum.count(updated.events, &(&1.id == "event-req_duplicate-0-effect_started-effect_1")) ==
             1

    assert {:error, :rejected} = RuntimeView.initial(%{reject?: true})

    assert_raise ArgumentError, ~r/must pass `agent:`/, fn ->
      MissingAgentView.agent_module(%{})
    end
  end

  defp snapshot do
    spec =
      Agent.Spec.new!(
        id: "agent_view_snapshot_agent",
        instructions: "Snapshot for AgentView.",
        model: %{provider: :test, id: "model"}
      )

    request = Turn.Request.new!(input: "Hello")

    state =
      Turn.State.new!(
        spec: spec,
        plan: Turn.Plan.new!(spec),
        request: request,
        agent_state: request.agent_state
      )

    Jidoka.Runtime.AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
  end
end
