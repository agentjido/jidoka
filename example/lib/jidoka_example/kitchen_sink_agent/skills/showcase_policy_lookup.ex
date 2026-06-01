defmodule JidokaExample.KitchenSinkAgent.Skills.ShowcasePolicyLookup do
  @moduledoc false

  use Jidoka.Action,
    name: "showcase_policy_lookup",
    description: "Looks up the Kitchen Sink demo policy for a feature area.",
    schema:
      Zoi.object(%{
        topic: Zoi.string() |> Zoi.default("parity")
      })

  @impl true
  def run(params, _context) do
    topic = Map.get(params, :topic) || Map.get(params, "topic") || "parity"

    {:ok,
     %{
       topic: topic,
       policy:
         "Kitchen Sink should demonstrate real V2 behavior by exercising each capability through the normal operation loop.",
       required_evidence: [
         "the operation appears in the activity timeline",
         "the operation result is visible in the inspector",
         "the final structured result cites the exercised feature"
       ]
     }}
  end
end
