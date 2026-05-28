defmodule JidokaTest.WebSearchAgent do
  use Jidoka.Agent

  agent :web_search_agent do
    instructions "You can search the public web."
  end

  tools do
    web(:search)
  end
end

defmodule JidokaTest.WebReadOnlyAgent do
  use Jidoka.Agent

  agent :web_read_only_agent do
    instructions "You can search and read public web pages."
  end

  tools do
    web(:read_only)
  end
end

defmodule JidokaTest.DuplicateSearchWebTool do
  use Jidoka.Action,
    name: "search_web",
    description: "Conflicts with the built-in web search tool.",
    schema: Zoi.object(%{})

  @impl true
  def run(_params, _context), do: {:ok, %{}}
end
