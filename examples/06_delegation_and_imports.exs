Mix.Task.run("app.start")

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

defmodule JidokaExamples.Delegation.ResearchSpecialist do
  defmodule Runtime do
    use Jido.Agent,
      name: "example_research_specialist_runtime",
      schema: Zoi.object(%{})
  end

  def name, do: "research_specialist"
  def runtime_module, do: Runtime
  def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)

  def chat(_pid, message, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    {:ok, %{summary: "research: #{message}", tenant: Map.get(context, :tenant, "none")}}
  end
end

defmodule JidokaExamples.Delegation.Orchestrator do
  use Jidoka.Agent

  agent :example_orchestrator do
    model :fast
    instructions "Use specialist operations when the task needs focused research."
  end

  tools do
    action JidokaExamples.Delegation.SearchCatalog
  end

  capabilities do
    subagent JidokaExamples.Delegation.ResearchSpecialist,
      as: "research_specialist",
      description: "Ask a focused research specialist."
  end
end

alias JidokaExamples.Delegation.{Orchestrator, SearchCatalog}

spec = %{
  "agent" => %{"id" => "portable_catalog_agent"},
  "defaults" => %{"instructions" => "Use the allowlisted catalog search tool."},
  "capabilities" => %{"tools" => ["search_catalog"]}
}

{:ok, imported} = Jidoka.import_agent(spec, available_tools: [SearchCatalog])
{:ok, encoded_json} = Jidoka.encode_agent(imported, format: :json)

IO.inspect(
  %{
    orchestrator_tools: Orchestrator.tool_names(),
    orchestrator_subagents: Enum.map(Orchestrator.subagents(), & &1.name),
    imported_tools: Enum.map(imported.tool_modules, & &1.name()),
    portable_spec_bytes: byte_size(encoded_json)
  },
  label: "delegation_and_imports"
)
