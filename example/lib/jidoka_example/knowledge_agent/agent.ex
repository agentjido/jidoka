defmodule JidokaExample.KnowledgeAgent.Agent do
  @guide """
  Use this route to see how Jidoka combines local skills, MCP tools, and
  optional browser research in one small knowledge agent.

  Ask about a Jidoka concept. The agent should call the local knowledge skill
  first, call the MCP docs note second, and only use browser search when the
  question needs outside context.

  This example keeps the knowledge sources explicit: skill instructions guide
  behavior, skill actions return local facts, MCP tools return external tool
  notes, and browser results can add live references when a Brave key is
  configured.
  """
  @moduledoc @guide

  use Jidoka.Agent

  alias JidokaExample.KnowledgeAgent.Controls.RequireEvidence
  alias JidokaExample.KnowledgeAgent.Skills.KnowledgeSkill

  @knowledge_result_schema Zoi.object(%{
                             answer: Zoi.string(),
                             evidence:
                               Zoi.array(
                                 Zoi.object(%{
                                   tool: Zoi.string(),
                                   summary: Zoi.string()
                                 })
                               ),
                             sources:
                               Zoi.array(
                                 Zoi.object(%{
                                   title: Zoi.string(),
                                   url: Zoi.string(),
                                   note: Zoi.string()
                                 })
                               )
                               |> Zoi.default([])
                           })

  def guide, do: @guide

  agent :knowledge_agent do
    instructions """
    You are a Jidoka knowledge agent for developers evaluating the package.

    For Jidoka, Jido, Runic, agent harness, DSL, controls, MCP, skills, memory,
    handoffs, or workflow questions, call knowledge_topic_lookup first. Then
    call mcp_docs_note for the same topic. Use browser search only when the
    user asks for current outside information or when local knowledge is not
    enough.

    Answer in practical developer language. Return a structured result with:

    - answer: one concise paragraph.
    - evidence: one entry per tool result you actually used.
    - sources: browser sources only when browser tools were called.

    Do not claim evidence from a source unless a tool returned it.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 1_100}}

    result schema: @knowledge_result_schema, max_repairs: 2
  end

  controls do
    max_turns 8
    timeout 60_000

    output RequireEvidence
  end

  tools do
    skill KnowledgeSkill

    mcp_tools endpoint: :knowledge_mcp,
              prefix: "mcp_",
              tools: [
                %{
                  name: "docs_note",
                  description: "Returns an MCP-hosted implementation note for a Jidoka topic.",
                  input_schema: %{
                    "type" => "object",
                    "properties" => %{"topic" => %{"type" => "string"}}
                  }
                }
              ]

    browser :public_web, mode: :read_only
  end
end
