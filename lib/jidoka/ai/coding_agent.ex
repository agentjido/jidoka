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
      Jidoka.Tools.GitStatus,
      Jidoka.Tools.GitDiff,
      Jidoka.Tools.WriteFile,
      Jidoka.Tools.EditFile,
      Jidoka.Tools.MixTest,
      Jidoka.Tools.MixCheck
    ],
    max_iterations: 6,
    tool_timeout_ms: 15_000,
    system_prompt: """
    You are a coding agent running inside a terminal workflow.
    Be direct, concrete, and concise.
    Use workspace tools before making claims about repository state.
    Read-only tools are always available when the permission mode allows reads.
    Mutation is limited to write_file and edit_file, and only when permission mode allows workspace writes.
    Project execution is limited to mix_test and mix_check; arbitrary shell commands are not available.
    """
end
