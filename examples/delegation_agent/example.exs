defmodule JidokaExamples.DelegationAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.Delegation.{BillingSpecialist, Orchestrator, SearchCatalog}

  @impl true
  def name, do: :delegation_agent

  @impl true
  def title, do: "Delegation Agent"

  @impl true
  def features, do: [:subagent, :handoff, :imported_agent]

  @impl true
  def summary, do: "Shows subagent calls, handoff ownership, and constrained imported specs."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    conversation_id = "example-handoff-#{System.unique_integer([:positive])}"

    try do
      {:ok, catalog_result} = SearchCatalog.run(%{query: "billing"}, %{})

      subagent_tool = find_tool!(Orchestrator, "research_specialist")
      {:ok, subagent_result} = subagent_tool.run(%{task: "Find escalation policy."}, %{tenant: "acme"})

      handoff_tool = find_tool!(Orchestrator, "billing_specialist")

      {:error, {:handoff, handoff}} =
        handoff_tool.run(
          %{message: "Please continue with invoice escalation.", summary: "Customer needs billing review."},
          %{conversation: conversation_id, tenant: "acme"}
        )

      Process.put(:jidoka_example_handoff_agent_id, handoff.to_agent_id)
      owner = Jidoka.handoff_owner(conversation_id)

      spec = %{
        "agent" => %{"id" => "portable_catalog_agent"},
        "defaults" => %{"instructions" => "Use the allowlisted catalog search tool.", "model" => "fast"},
        "capabilities" => %{"tools" => ["search_catalog"], "handoffs" => ["example_billing_specialist"]}
      }

      {:ok, imported} =
        Jidoka.import_agent(spec,
          available_tools: [SearchCatalog],
          available_handoffs: [BillingSpecialist]
        )

      {:ok, encoded_json} = Jidoka.encode_agent(imported, format: :json)

      {:ok,
       %{
         example: name(),
         mode: :verify,
         orchestrator_tools: Orchestrator.tool_names(),
         subagent_result: subagent_result.result,
         catalog_result: catalog_result,
         handoff: %{name: handoff.name, to_agent_id: handoff.to_agent_id, owner?: not is_nil(owner)},
         imported_tools: Enum.map(imported.tool_modules, & &1.name()),
         portable_spec_bytes: byte_size(encoded_json)
       }}
    after
      Jidoka.reset_handoff(conversation_id)
      maybe_stop_handoff_owner()
      Process.delete(:jidoka_example_handoff_agent_id)
    end
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt =
        JidokaExamples.prompt(
          opts,
          "Search the catalog for billing escalation guidance, then summarize whether a handoff is needed."
        )

      session =
        Jidoka.session(Orchestrator, "delegation-live", context: %{tenant: "acme", conversation_id: "delegation-live"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 60_000)

        with {:ok, response} <- JidokaExamples.live_chat_summary(result) do
          {:ok,
           %{
             example: name(),
             mode: :live,
             provider_env: provider_env,
             response: response
           }}
        end
      after
        if pid = Jidoka.Session.whereis(session), do: Jidoka.stop_agent(pid)
        Jidoka.reset_handoff("delegation-live")
      end
    end
  end

  defp find_tool!(agent, name) do
    Enum.find(agent.tools(), &(&1.name() == name)) ||
      raise "missing generated tool #{inspect(name)} for #{inspect(agent)}"
  end

  defp maybe_stop_handoff_owner do
    case Process.get(:jidoka_example_handoff_agent_id) do
      nil ->
        :ok

      agent_id ->
        if pid = Jidoka.whereis(agent_id), do: Jidoka.stop_agent(pid)
    end
  end
end
