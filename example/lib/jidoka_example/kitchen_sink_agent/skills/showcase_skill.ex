defmodule JidokaExample.KitchenSinkAgent.Skills.ShowcaseSkill do
  @moduledoc false

  use Jido.AI.Skill,
    name: "jidoka-showcase",
    description:
      "Guides the Kitchen Sink agent to prove feature behavior with concrete evidence.",
    allowed_tools: ["showcase_policy_lookup"],
    actions: [JidokaExample.KitchenSinkAgent.Skills.ShowcasePolicyLookup],
    body: """
    # Jidoka Showcase Skill

    Use showcase_policy_lookup when the user asks for the Kitchen Sink demo,
    feature parity, or proof that a capability is wired through the runtime.

    Prefer evidence from operation results over claims about configured
    features.
    """
end
