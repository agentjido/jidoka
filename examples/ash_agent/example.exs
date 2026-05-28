defmodule JidokaExamples.AshAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.Ash.{Accounts, Agent, User}

  @impl true
  def name, do: :ash_agent

  @impl true
  def title, do: "Ash Resource Agent"

  @impl true
  def features, do: [:ash_resource, :actor_context]

  @impl true
  def summary, do: "Expands an Ash resource into tools and validates actor/domain context."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    {:error, missing_actor} =
      Jidoka.Agent.prepare_chat_opts(
        [context: %{}],
        %{domain: Accounts, require_actor?: true}
      )

    {:ok, prepared_opts} =
      Jidoka.Agent.prepare_chat_opts(
        [context: %{actor: %{id: "user-1"}}],
        %{domain: Accounts, require_actor?: true}
      )

    tool_context = Keyword.fetch!(prepared_opts, :tool_context)

    {:ok,
     %{
       example: name(),
       mode: :verify,
       agent_id: Agent.id(),
       ash_resources: Enum.map(Agent.ash_resources(), &inspect/1),
       ash_domain: inspect(Agent.ash_domain()),
       requires_actor?: Agent.requires_actor?(),
       tool_names: Agent.tool_names(),
       missing_actor_error: Jidoka.Error.format(missing_actor),
       prepared_tool_context: %{
         actor: Map.get(tool_context, :actor),
         domain: inspect(Map.get(tool_context, :domain))
       },
       resource: inspect(User)
     }}
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt =
        JidokaExamples.prompt(
          opts,
          "Describe the Ash user tools available to you. Do not call the tools."
        )

      session =
        Jidoka.session(Agent, "ash-live", context: %{actor: %{id: "user_live"}})

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
      end
    end
  end
end
