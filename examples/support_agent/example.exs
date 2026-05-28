defmodule JidokaExamples.SupportAgentExample do
  @behaviour JidokaExamples.Example

  alias JidokaExamples.ActionsControls.{LoadTicket, RequireApproval, SupportAgent}

  @impl true
  def name, do: :support_agent

  @impl true
  def title, do: "Support Agent"

  @impl true
  def features, do: [:actions, :controls, :credentials, :human_in_the_loop]

  @impl true
  def summary, do: "Shows provider-visible actions, operation controls, and credential references."

  @impl true
  def run(opts \\ []) do
    case JidokaExamples.mode(opts) do
      :live -> run_live(opts)
      :verify -> run_verify(opts)
    end
  end

  defp run_verify(_opts) do
    credential = credential()
    context = %{account_id: "acct_123", actor_id: "user_123", credential_ref: credential}

    {:ok, ticket} = LoadTicket.run(%{id: "ticket-123"}, context)

    approval =
      RequireApproval.call(%Jidoka.Guardrails.Tool{
        agent: %{id: SupportAgent.id()},
        server: self(),
        request_id: "req-example",
        tool_name: "load_ticket",
        operation_kind: :action,
        tool_call_id: "tool-call-example",
        arguments: %{id: "ticket-123"},
        context: context,
        metadata: %{},
        request_opts: %{}
      })

    {:ok,
     %{
       example: name(),
       mode: :verify,
       agent_id: SupportAgent.id(),
       tool_names: SupportAgent.tool_names(),
       ticket: ticket,
       credential_metadata: Jidoka.Credential.metadata(credential),
       approval: approval_summary(approval)
     }}
  end

  defp run_live(opts) do
    with {:ok, provider_env} <- JidokaExamples.require_live_provider(opts) do
      prompt =
        JidokaExamples.prompt(
          opts,
          "Triage ticket ticket-123. Use the load_ticket tool first, then recommend the next step."
        )

      session =
        Jidoka.session(SupportAgent, "support-live",
          context: %{account_id: "acct_live", actor_id: "user_live", credential_ref: credential()}
        )

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

  defp credential do
    Jidoka.Credential.new!(
      provider: :zendesk,
      account: "acct_123",
      actor: "user_123",
      scopes: ["tickets:read"],
      lease_id: "lease_123",
      confirmation_required: true
    )
  end

  defp approval_summary({:interrupt, %Jidoka.Interrupt{} = interrupt}),
    do: Map.take(interrupt, [:kind, :message, :data])

  defp approval_summary(%Jidoka.Interrupt{} = interrupt), do: Map.take(interrupt, [:kind, :message, :data])
  defp approval_summary(other), do: other
end
