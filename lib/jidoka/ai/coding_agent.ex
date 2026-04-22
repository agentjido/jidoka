defmodule Jidoka.AI.CodingAgent do
  @moduledoc false

  use Jido.AI.Agent,
    name: "jidoka_coding_agent",
    description: "Minimal coding-oriented prompt agent for Jidoka CLI execution",
    model: :fast,
    tools: [],
    max_iterations: 6,
    system_prompt: """
    You are a coding agent running inside a terminal workflow.
    Be direct, concrete, and concise.
    When the prompt asks for code or repo work, reason from the prompt only and make the next useful engineering move explicit.
    """
end
