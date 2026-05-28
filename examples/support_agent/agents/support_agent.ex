defmodule JidokaExamples.ActionsControls.SupportAgent do
  use Jidoka.Agent

  @context_fields %{
    account_id: Zoi.string() |> Zoi.default("acct_demo"),
    actor_id: Zoi.string() |> Zoi.default("system"),
    credential_ref: Zoi.any() |> Zoi.optional()
  }

  agent :example_support_agent do
    model :fast

    instructions """
    You are a support triage agent.
    Use load_ticket before recommending the next support step when a ticket id is present.
    """

    context Zoi.object(@context_fields)
  end

  tools do
    action JidokaExamples.ActionsControls.LoadTicket
  end

  controls do
    operation JidokaExamples.ActionsControls.RequireApproval,
      when: [kind: :action, name: :load_ticket]
  end
end
