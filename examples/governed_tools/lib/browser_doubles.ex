defmodule JidokaExamples.GovernedTools.BrowserDoubles.SearchWeb do
  @moduledoc false

  def run(params, _context) do
    {:ok,
     %{
       results: [
         %{
           title: "Jidoka documentation",
           url: "https://docs.example.com/guides/tools-and-operations"
         }
       ],
       query: params.query
     }}
  end
end

defmodule JidokaExamples.GovernedTools.BrowserDoubles.ReadPage do
  @moduledoc false

  def run(params, _context) do
    {:ok,
     %{
       content: "Jidoka tools use typed schemas, explicit controls, and deterministic effects.",
       title: "Tools And Operations",
       url: params.url
     }}
  end
end

defmodule JidokaExamples.GovernedTools.BrowserDoubles.SnapshotUrl do
  @moduledoc false

  def run(params, _context) do
    {:ok,
     %{
       content: "# Tools And Operations\n\nTyped schemas and explicit controls.",
       url: params.url
     }}
  end
end
