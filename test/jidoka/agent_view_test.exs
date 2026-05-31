defmodule Jidoka.AgentViewTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.AgentView
  alias Jidoka.Effect
  alias Jidoka.Turn

  defmodule DemoAgent do
    use Jidoka.Agent

    agent :demo_agent
  end

  defmodule DemoView do
    use Jidoka.AgentView, agent: DemoAgent
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
end
