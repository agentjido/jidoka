defmodule JidokaExamples.Delegation.Orchestrator do
  use Jidoka.Agent

  agent :example_delegation_orchestrator do
    model :fast
    instructions "Use specialist operations when the task needs focused research or handoff."
  end

  tools do
    action JidokaExamples.Delegation.SearchCatalog

    subagent JidokaExamples.Delegation.ResearchSpecialist,
      as: "research_specialist",
      description: "Ask a focused research specialist.",
      result: :structured

    handoff JidokaExamples.Delegation.BillingSpecialist,
      as: :billing_specialist,
      description: "Transfer billing ownership to the billing specialist."
  end
end
