defmodule JidokaExamples.KnowledgeAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.Knowledge.{Agent, FakeMCPSync, PolicyLookup, SkillPolicyLookup}

  @impl true
  def name, do: :knowledge_agent

  @impl true
  def title, do: "Knowledge Agent"

  @impl true
  def features, do: [:skills, :mcp_tools, :web]

  @impl true
  def summary, do: "Exercises skills, plugin tools, MCP sync, and web tool exposure."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    previous_sync = Application.get_env(:jidoka, :mcp_sync_module)
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    try do
      {:ok, policy} = PolicyLookup.run(%{topic: "billing escalation"}, %{})
      {:ok, skill_policy} = SkillPolicyLookup.run(%{topic: "billing change"}, %{})

      runtime_agent = Agent.runtime_module().new(id: "example-knowledge-runtime")

      {:ok, _agent, {:ai_react_start, skill_params}} =
        Jidoka.Skill.on_before_cmd(
          runtime_agent,
          {:ai_react_start,
           %{
             query: "What is the escalation policy?",
             allowed_tools: Agent.tool_names(),
             tool_context: %{tenant: "acme"}
           }},
          Agent.skills()
        )

      {:ok, _agent, _action} = Jidoka.MCP.on_before_cmd(runtime_agent, {:ai_react_start, %{}}, Agent.mcp_tools())

      {:ok,
       %{
         example: name(),
         mode: :verify,
         agent_id: Agent.id(),
         tool_names: Agent.tool_names(),
         web_tool_names: Agent.web_tool_names(),
         skill_names: skill_params.tool_context[Jidoka.Skill.context_key()].names,
         allowed_tools_after_skill: skill_params.allowed_tools,
         mcp_tools: Agent.mcp_tools(),
         policy_lookup: policy,
         skill_policy_lookup: skill_policy
       }}
    after
      restore_mcp_sync(previous_sync)
    end
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt =
        JidokaExamples.prompt(
          opts,
          "Use available policy tooling to explain the enterprise billing escalation rule."
        )

      session =
        Jidoka.session(Agent, "knowledge-live", context: %{session: "knowledge-live", tenant: "acme"})

      try do
        result = Jidoka.chat(session, prompt, timeout: 90_000)

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
      end
    end
  end

  defp restore_mcp_sync(nil), do: Application.delete_env(:jidoka, :mcp_sync_module)
  defp restore_mcp_sync(module), do: Application.put_env(:jidoka, :mcp_sync_module, module)
end
