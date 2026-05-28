defmodule JidokaExamples.Knowledge.SkillPolicyLookup do
  use Jidoka.Action,
    name: "skill_policy_lookup",
    description: "Looks up a policy snippet for the support policy skill.",
    schema: Zoi.object(%{topic: Zoi.string()})

  @impl true
  def run(%{topic: topic}, _context) do
    {:ok, %{topic: topic, policy: "Skill policy: confirm account ownership before changing billing settings."}}
  end
end
