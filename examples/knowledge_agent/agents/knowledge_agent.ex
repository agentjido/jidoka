defmodule JidokaExamples.Knowledge.Agent do
  use Jidoka.Agent

  @context_fields %{
    session: Zoi.string() |> Zoi.default("knowledge-session"),
    tenant: Zoi.string() |> Zoi.default("acme")
  }

  agent :example_knowledge_agent do
    model :fast
    instructions "Answer support policy questions using available skills, MCP, and web tools."

    context Zoi.object(@context_fields)
  end

  tools do
    plugin JidokaExamples.Knowledge.PolicyPlugin
    skill JidokaExamples.Knowledge.PolicySkill
    mcp_tools endpoint: :local_fs, prefix: "fs_"
    web :search
  end
end
