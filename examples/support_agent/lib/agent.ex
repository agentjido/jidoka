defmodule JidokaExamples.SupportAgent.Agent do
  @guide """
  Start here to see the smallest useful Jidoka agent running under Jido
  supervision: one agent, one deterministic action, and one operation control.

  Ask about order A1001. The agent calls lookup_order before it answers. The
  action result becomes the next model observation and appears in the Activity
  tab.

  The same agent also supports a deterministic review path. A credential
  reference makes the control pause the operation until an operator approves
  it.
  """
  @moduledoc @guide

  use Jidoka.Agent

  alias JidokaExamples.SupportAgent.Actions.LookupOrder
  alias JidokaExamples.SupportAgent.Controls.RequireOrderApproval

  @context_schema Zoi.object(%{
                    account_id: Zoi.string() |> Zoi.default("acct_demo"),
                    actor_id: Zoi.string() |> Zoi.default("system"),
                    credential_ref: Zoi.string() |> Zoi.optional()
                  })

  def guide, do: @guide

  agent :support_agent do
    instructions """
    You are a concise customer support agent.

    When a customer asks about an order, call lookup_order exactly once before
    you answer. Use only the status, ETA, carrier, summary, and recommended
    action that the tool returns. Do not invent order details.

    If the order is not found, explain that clearly and ask for the correct
    order id.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 700}}
    context @context_schema
  end

  tools do
    action LookupOrder
  end

  controls do
    max_turns 4
    timeout 20_000

    operation RequireOrderApproval,
      when: [kind: :action, name: "lookup_order"]
  end
end
