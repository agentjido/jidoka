defmodule JidokaExamples.Delegation.SearchCatalog do
  use Jidoka.Action,
    name: "search_catalog",
    description: "Searches a small internal knowledge catalog.",
    schema: Zoi.object(%{query: Zoi.string()})

  @impl true
  def run(%{query: query}, _context) do
    {:ok, %{matches: [%{id: "kb_1", title: "Billing escalation", score: 0.92}], query: query}}
  end
end
