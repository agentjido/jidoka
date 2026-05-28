defmodule JidokaExamples.Knowledge.PolicyLookup do
  use Jidoka.Action,
    name: "policy_lookup",
    description: "Looks up an internal policy snippet.",
    schema: Zoi.object(%{topic: Zoi.string()})

  @impl true
  def run(%{topic: topic}, _context) do
    {:ok, %{topic: topic, policy: "Enterprise billing escalations require a named owner within one hour."}}
  end
end
