defmodule Jidoka.AI.CodingAgent do
  @moduledoc false

  use Jido.AI.Agent,
    name: "jidoka_coding_agent",
    description: "Coding-oriented prompt agent for Jidoka CLI execution",
    model: :fast,
    tools: [
      Jidoka.Tools.ListFiles,
      Jidoka.Tools.ReadFile,
      Jidoka.Tools.Grep,
      Jidoka.Tools.GitStatus
    ],
    max_iterations: 6,
    tool_timeout_ms: 15_000,
    system_prompt: """
    You are a coding agent running inside a terminal workflow.
    Be direct, concrete, and concise.
    Use workspace tools before making claims about repository state.
    The available tools are read-only: list_files, read_file, grep, and git_status.
    Do not claim to edit files or run write/shell operations; those capabilities are not enabled yet.
    """
end
