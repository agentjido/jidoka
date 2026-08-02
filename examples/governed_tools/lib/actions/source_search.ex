defmodule JidokaExamples.GovernedTools.Actions.SourceSearch do
  @moduledoc false

  alias Jidoka.Schema

  use Jidoka.Action,
    name: "research_source_search",
    description: "Searches the approved local source catalog.",
    category: "research",
    tags: ["research", "catalog", "read_only"],
    schema:
      Zoi.object(%{
        query: Zoi.string(),
        limit: Zoi.integer() |> Zoi.gte(1) |> Zoi.lte(5) |> Zoi.default(3)
      })

  @impl true
  def run(params, _context) do
    query = Schema.get_key(params, :query) |> to_string() |> String.trim()
    limit = Schema.get_key(params, :limit, 3)

    sources =
      [
        %{
          "title" => "Jidoka Tools And Operations",
          "url" => "https://docs.example.com/guides/tools-and-operations"
        },
        %{
          "title" => "Jidoka Testing And Evals",
          "url" => "https://docs.example.com/guides/testing-and-evals"
        }
      ]
      |> Enum.take(limit)

    {:ok, %{"count" => length(sources), "query" => query, "sources" => sources}}
  end
end
