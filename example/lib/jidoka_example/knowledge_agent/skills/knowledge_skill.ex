defmodule JidokaExample.KnowledgeAgent.Skills.KnowledgeSkill do
  @moduledoc false

  use Jido.AI.Skill,
    name: "jidoka-knowledge",
    description: "Provides local Jidoka implementation knowledge for developer questions.",
    allowed_tools: ["knowledge_topic_lookup"],
    actions: [JidokaExample.KnowledgeAgent.Skills.KnowledgeTopicLookup],
    body: """
    # Jidoka Knowledge Skill

    Use knowledge_topic_lookup before answering questions about Jidoka's DSL,
    Runic turn spine, controls, operation sources, skills, MCP tools, memory,
    handoffs, workflows, and AgentView projections.

    Treat returned local facts as implementation context, not as a substitute
    for tool evidence in the final structured result.
    """
end
