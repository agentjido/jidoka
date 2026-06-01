defmodule JidokaExample.DebugAgentTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias JidokaExample.DebugAgent.Actions.InspectAgent
  alias JidokaExample.DebugAgent.Actions.PreflightAgent
  alias JidokaExample.DebugAgent.Agent
  alias JidokaExample.DebugAgent.Targets

  test "agent spec exposes debug actions" do
    spec = Agent.spec()
    operations = Map.new(spec.operations, &{&1.name, &1})

    assert %Operation{} = operations["inspect_agent"]
    assert %Operation{} = operations["preflight_agent"]

    assert Operation.kind(operations["inspect_agent"]) == :action
    assert Operation.kind(operations["preflight_agent"]) == :action
  end

  test "target catalog uses fixed ids without dynamic atom conversion" do
    assert "support" in Targets.ids()
    assert "knowledge" in Targets.ids()
    assert "kitchen_sink" in Targets.ids()

    assert {:ok, %{module: JidokaExample.SupportAgent.Agent}} = Targets.fetch("support")
    assert {:ok, %{module: JidokaExample.KitchenSinkAgent.Agent}} = Targets.fetch(:kitchen_sink)
    assert {:error, {:unknown_debug_target, "missing", ids}} = Targets.fetch("missing")
    assert "support" in ids
  end

  test "inspect target summarizes compiled agent structure" do
    assert {:ok, result} = Targets.inspect_target("support")

    assert result["target"] == "support"
    assert result["agent_id"] == "support_agent"
    assert result["operation_count"] == 1
    assert [%{"name" => "lookup_order", "kind" => "action"}] = result["operations"]
    assert result["inspection"].kind == :agent
  end

  test "preflight target assembles prompt and operations without effects" do
    assert {:ok, result} = Targets.preflight_target("support", "Can you check order A1001?")

    assert result["target"] == "support"
    assert result["message_count"] == 2
    assert [%{"role" => "system"}, %{"role" => "user"}] = result["messages"]
    assert [%{"name" => "lookup_order", "kind" => "action"}] = result["operations"]
    assert [%{"event" => "prompt_assembled", "seq" => 0}] = result["timeline"]
  end

  test "debug actions wrap inspect and preflight APIs" do
    assert {:ok, inspect_result} = InspectAgent.run(%{"target" => "knowledge"}, %{})
    assert inspect_result["agent_id"] == "knowledge_agent"

    assert {:ok, preflight_result} =
             PreflightAgent.run(
               %{"target" => "knowledge", "prompt" => "Explain skills and MCP."},
               %{}
             )

    assert preflight_result["target"] == "knowledge"
    assert Enum.any?(preflight_result["operations"], &(&1["name"] == "knowledge_topic_lookup"))
    assert Enum.any?(preflight_result["operations"], &(&1["name"] == "mcp_docs_note"))
  end
end
