defmodule JidokaExamples.GovernedTools.Catalog do
  @moduledoc false

  alias Jido.Action.Catalog
  alias JidokaExamples.GovernedTools.Actions.SourceSearch

  def catalog do
    Catalog.new!(id: "governed-research", name: "Governed Research")
    |> Catalog.register!(SourceSearch,
      id: "research.source.search",
      description: "Search approved research sources.",
      visibility: :hidden,
      read_only?: true,
      metadata: %{
        "lua" => %{
          "returns" => "Returns approved source titles and URLs.",
          "example" =>
            ~s|{id = "search", tool = "research.source.search", arguments = {query = "Jidoka", limit = 2}}|
        }
      }
    )
  end

  def templates do
    %{
      source_search: """
      return jidoka.workflow({
        id = "governed_source_search",
        steps = {
          {id = "search", tool = "research.source.search", arguments = {query = "Jidoka", limit = 2}}
        },
        output = "search"
      })
      """
    }
  end
end
