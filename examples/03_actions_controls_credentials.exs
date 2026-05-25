Mix.Task.run("app.start")

defmodule JidokaExamples.ActionsControls.LoadTicket do
  use Jidoka.Action,
    name: "load_ticket",
    description: "Loads a support ticket from the application database.",
    schema: Zoi.object(%{id: Zoi.string()})

  @impl true
  def run(%{id: id}, context) do
    {:ok,
     %{
       id: id,
       account_id: Map.fetch!(context, :account_id),
       status: :open,
       subject: "Invoice question"
     }}
  end
end

defmodule JidokaExamples.ActionsControls.RequireApproval do
  use Jidoka.Control, name: "require_approval"

  @impl true
  def call(%Jidoka.Guardrails.Tool{operation_kind: :action, tool_name: tool_name, context: context}) do
    if Map.get(context, :credential_ref) && to_string(tool_name) == "load_ticket" do
      Jidoka.Approval.request("Approve authenticated ticket access.",
        data: %{tool: to_string(tool_name), account_id: context.account_id}
      )
    else
      :cont
    end
  end
end

defmodule JidokaExamples.ActionsControls.SupportAgent do
  use Jidoka.Agent

  agent :example_support_agent do
    model :fast
    instructions "Use ticket data before recommending the next support step."

    context(
      Zoi.object(%{
        account_id: Zoi.string() |> Zoi.default("acct_demo"),
        actor_id: Zoi.string() |> Zoi.default("system"),
        credential_ref: Zoi.any() |> Zoi.optional()
      })
    )
  end

  tools do
    action JidokaExamples.ActionsControls.LoadTicket
  end

  controls do
    operation(JidokaExamples.ActionsControls.RequireApproval,
      when: [kind: :action, name: :load_ticket]
    )
  end
end

alias JidokaExamples.ActionsControls.{LoadTicket, RequireApproval}

credential =
  Jidoka.Credential.new!(
    provider: :zendesk,
    account: "acct_123",
    actor: "user_123",
    scopes: ["tickets:read"],
    lease_id: "lease_123",
    confirmation_required: true
  )

context = %{account_id: "acct_123", actor_id: "user_123", credential_ref: credential}

{:ok, ticket} = LoadTicket.run(%{id: "ticket-123"}, context)

approval =
  RequireApproval.call(%Jidoka.Guardrails.Tool{
    agent: %{id: "example_support_agent"},
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

IO.inspect(
  %{
    ticket: ticket,
    credential_metadata: Jidoka.Credential.metadata(credential),
    approval: approval
  },
  label: "actions_controls_credentials"
)
