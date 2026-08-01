defmodule JidokaExamples.DurableRefund.Agent do
  @moduledoc """
  Deterministic refund agent for execution and continuation proofs.
  """

  use Jidoka.Agent

  alias JidokaExamples.DurableRefund.Actions.IssueRefund
  alias JidokaExamples.DurableRefund.Controls.AllowRefund

  agent :durable_refund do
    model %{provider: :test, id: "durable-refund-script"}

    instructions """
    Issue one refund when the scripted model requests it. Report success only
    after the operation result is present. Keep all answers concise.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 64}}
  end

  tools do
    action(IssueRefund, idempotency: :unsafe_once)
  end

  controls do
    max_turns 4
    timeout 10_000

    operation AllowRefund,
      when: [kind: :action, name: "issue_refund"]
  end
end
