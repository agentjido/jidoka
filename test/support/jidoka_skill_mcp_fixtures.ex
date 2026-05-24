defmodule JidokaTest.ModuleMathSkill do
  use Jido.AI.Skill,
    name: "module-math-skill",
    description: "Provides multiply_numbers and enforces a calculation workflow.",
    allowed_tools: ["multiply_numbers"],
    actions: [JidokaTest.MultiplyNumbers],
    body: """
    # Module Math Skill

    Use the multiply_numbers tool whenever multiplication is required.
    Keep the response short.
    """
end

defmodule JidokaTest.SkillAgent do
  use Jidoka.Agent

  agent :skill_agent do
    model :fast
    instructions "You can use skills."
  end

  capabilities do
    skill JidokaTest.ModuleMathSkill
  end
end

defmodule JidokaTest.RuntimeSkillAgent do
  use Jidoka.Agent

  agent :runtime_skill_agent do
    model :fast
    instructions "You can use runtime skills."
  end

  capabilities do
    skill "math-discipline"
    load_path "../fixtures/skills"
  end
end

defmodule JidokaTest.MCPAgent do
  use Jidoka.Agent

  agent :mcp_agent do
    model :fast
    instructions "You can use MCP-synced tools."
  end

  capabilities do
    mcp_tools endpoint: :github, prefix: "github_"
  end
end

defmodule JidokaTest.LocalFSMCPAgent do
  use Jidoka.Agent

  agent :local_fsmcp_agent do
    model :fast
    instructions "You can use filesystem MCP tools."
  end

  capabilities do
    mcp_tools endpoint: :local_fs, prefix: "fs_"
  end
end

defmodule JidokaTest.InlineMCPAgent do
  use Jidoka.Agent

  agent :inline_mcp_agent do
    model :fast
    instructions "You can use an inline MCP endpoint."
  end

  capabilities do
    mcp_tools endpoint: :inline_fs,
              prefix: "inline_",
              transport: {:stdio, command: "echo"},
              client_info: %{name: "jidoka-test", version: "0.1.0"},
              timeouts: %{request_ms: 15_000}
  end
end

defmodule JidokaTest.FakeMCPSync do
  def run(params, _context) do
    send(self(), {:mcp_sync_called, params})
    {:ok, %{registered_count: 1}}
  end
end

defmodule JidokaTest.FailingMCPSync do
  def run(params, _context) do
    send(self(), {:mcp_sync_called, params})
    {:error, :server_capabilities_not_set}
  end
end
