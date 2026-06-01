defmodule JidokaExample.KitchenSinkAgentTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias JidokaExample.KitchenSinkAgent.Agent
  alias JidokaExample.KitchenSinkAgent.Actions.ShowContext
  alias JidokaExample.KitchenSinkAgent.Controls.AllowSpecialistHandoff
  alias JidokaExample.KitchenSinkAgent.Controls.BlockInternalPrompt
  alias JidokaExample.KitchenSinkAgent.Controls.RequireShowcaseSummary

  test "agent spec composes all stable operation source types" do
    spec = Agent.spec()
    operations = Map.new(spec.operations, &{&1.name, &1})

    assert %Operation{} = operations["show_context"]
    assert %Operation{} = operations["showcase_policy_lookup"]
    assert %Operation{} = operations["mcp_showcase_notes"]
    assert %Operation{} = operations["evidence_specialist"]
    assert %Operation{} = operations["refund_specialist"]
    assert %Operation{} = operations["build_feature_summary"]
    assert %Operation{} = operations["lookup_order"]
    assert %Operation{} = operations["remember_preference"]
    assert %Operation{} = operations["issue_refund"]
    assert %Operation{} = operations["create_customer"]
    assert %Operation{} = operations["list_customers"]
    assert %Operation{} = operations["search_web"]
    assert %Operation{} = operations["read_page"]
    assert %Operation{} = operations["catalog_jido_actions"]

    assert Operation.kind(operations["show_context"]) == :action
    assert Operation.kind(operations["showcase_policy_lookup"]) == :skill
    assert Operation.kind(operations["mcp_showcase_notes"]) == :mcp
    assert Operation.kind(operations["evidence_specialist"]) == :subagent
    assert Operation.kind(operations["refund_specialist"]) == :handoff
    assert Operation.kind(operations["build_feature_summary"]) == :workflow
    assert Operation.kind(operations["create_customer"]) == :ash_resource
    assert Operation.kind(operations["search_web"]) == :browser
    assert Operation.kind(operations["catalog_jido_actions"]) == :catalog
  end

  test "agent spec includes skill instructions and metadata" do
    spec = Agent.spec()

    assert spec.instructions =~ "jidoka-showcase"
    assert spec.instructions =~ "Use showcase_policy_lookup"

    assert Enum.any?(spec.metadata["tool_sources"], fn
             %{"source" => "skill", "name" => "jidoka-showcase"} -> true
             _source -> false
           end)
  end

  test "agent spec includes memory and each control boundary" do
    spec = Agent.spec()

    assert spec.context_schema
    assert spec.memory.scope == :session
    assert spec.memory.max_entries == 50
    assert spec.controls.max_turns == 18
    assert spec.controls.timeout_ms == 90_000
    assert Enum.any?(spec.controls.inputs, &(&1.control == BlockInternalPrompt))
    assert Enum.any?(spec.controls.outputs, &(&1.control == RequireShowcaseSummary))

    assert Enum.any?(spec.controls.operations, fn control ->
             control.control == JidokaExample.ApprovalAgent.Controls.RequireRefundApproval and
               control.match[:name] == "issue_refund"
           end)

    assert Enum.any?(spec.controls.operations, fn control ->
             control.control == AllowSpecialistHandoff and control.match[:name] == "refund_specialist"
           end)
  end

  test "show context action returns public context keys only" do
    assert {:ok, result} =
             ShowContext.run(
               %{},
               %{
                 agent_module: Agent,
                 actor: %{id: "dev-1", role: "developer"},
                 channel: "kitchen_sink",
                 example: "kitchen_sink_agent",
                 memory_store: :private,
                 session_id: "session_123",
                 surface: "test",
                 tenant: "demo"
               }
             )

    assert result["actor"] == %{id: "dev-1", role: "developer"}
    assert result["channel"] == "kitchen_sink"
    assert result["example"] == "kitchen_sink_agent"
    assert result["session_id"] == "session_123"
    assert result["surface"] == "test"
    assert result["tenant"] == "demo"
    assert "agent_module" not in result["keys"]
    assert "memory_store" not in result["keys"]
  end
end
