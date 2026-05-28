defmodule JidokaExamples.Knowledge.PolicySkill do
  use Jido.AI.Skill,
    name: "support-policy-skill",
    description: "Adds a support policy workflow and narrows allowed tools.",
    allowed_tools: ["skill_policy_lookup"],
    actions: [JidokaExamples.Knowledge.SkillPolicyLookup],
    body: """
    # Support Policy Skill

    Use skill_policy_lookup when the user asks about support policy or escalation rules.
    Keep answers grounded in the returned policy snippet.
    """
end
