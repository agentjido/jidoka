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
