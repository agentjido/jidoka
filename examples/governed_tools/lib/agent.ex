defmodule JidokaExamples.GovernedTools.Agent do
  @moduledoc "Agent for governed tool discovery, read-only browsing, and deterministic eval examples."

  use Jidoka.Agent

  alias JidokaExamples.GovernedTools.{Catalog, ResearchSkill}

  agent :governed_tools do
    model %{provider: :test, id: "governed-tools-model"}

    instructions """
    Use the smallest approved tool set. Discover catalog entries before
    execution. Browse only allowlisted public documentation. Cite evidence.
    """
  end

  tools do
    skill ResearchSkill
    catalog Catalog

    browser :documentation,
      mode: :read_only,
      allow: ["https://docs.example.com/guides"]
  end

  controls do
    max_turns 6
    timeout 10_000
  end
end
