defmodule JidokaExample.KnowledgeAgentTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias JidokaExample.KnowledgeAgent.Agent
  alias JidokaExample.KnowledgeAgent.Controls.RequireEvidence
  alias JidokaExample.KnowledgeAgent.MCP.LocalClient
  alias JidokaExample.KnowledgeAgent.Skills.KnowledgeTopicLookup

  test "agent spec exposes skill, MCP, and browser operation sources" do
    spec = Agent.spec()
    operations = Map.new(spec.operations, &{&1.name, &1})

    assert %Operation{} = operations["knowledge_topic_lookup"]
    assert %Operation{} = operations["mcp_docs_note"]
    assert %Operation{} = operations["search_web"]
    assert %Operation{} = operations["read_page"]

    assert Operation.kind(operations["knowledge_topic_lookup"]) == :skill
    assert Operation.kind(operations["mcp_docs_note"]) == :mcp
    assert Operation.kind(operations["search_web"]) == :browser
  end

  test "skill prompt and metadata are folded into the agent spec" do
    spec = Agent.spec()

    assert spec.instructions =~ "jidoka-knowledge"
    assert spec.instructions =~ "Use knowledge_topic_lookup"

    assert Enum.any?(spec.metadata["tool_sources"], fn
             %{"source" => "skill", "name" => "jidoka-knowledge"} -> true
             _source -> false
           end)
  end

  test "knowledge lookup returns local implementation notes" do
    assert {:ok, result} = KnowledgeTopicLookup.run(%{topic: "How do controls work?"}, %{})

    assert result["topic"] == "controls"
    assert result["summary"] =~ "boundary policies"
    assert "operation controls can interrupt a planned effect for review" in result["details"]
  end

  test "local MCP client returns a normalized docs note" do
    assert {:ok, %{data: %{"tools" => tools}}} = LocalClient.list_tools(:knowledge_mcp, [])
    assert [%{"name" => "docs_note"}] = tools

    assert {:ok, %{data: result}} =
             LocalClient.call_tool(:knowledge_mcp, "docs_note", %{"topic" => "skills"}, [])

    assert result["topic"] == "skills"
    assert result["note"] =~ "Knowledge Agent MCP client"
  end

  test "output control requires tool evidence" do
    assert :allow =
             RequireEvidence.call(%{
               boundary: :output,
               result_value: %{evidence: [%{tool: "knowledge_topic_lookup", summary: "local notes"}]}
             })

    assert {:block, :missing_knowledge_evidence} =
             RequireEvidence.call(%{boundary: :output, result_value: %{evidence: []}})
  end
end
