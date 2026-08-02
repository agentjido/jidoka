defmodule JidokaExamples.GovernedTools.ResearchSkill do
  @moduledoc false

  use Jido.AI.Skill,
    name: "governed-research",
    description: "Adds one approved research-policy tool and its instructions.",
    allowed_tools: ["research_policy_lookup"],
    actions: [JidokaExamples.GovernedTools.Actions.PolicyLookup],
    body: """
    # Governed Research

    Call research_policy_lookup before research work. Use only approved public
    sources, keep the tool set bounded, and cite source URLs.
    """
end
