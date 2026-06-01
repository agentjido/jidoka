defmodule JidokaExample.ApprovalAgent.Agent do
  @guide """
  Use this route to see a human review interrupt before a sensitive operation
  runs.

  Ask for a refund on order B2002. The agent should plan the refund operation,
  Jidoka should hibernate the turn for review, and the UI should let you
  approve or reject the pending action.

  The review request is data on the snapshot. Approving resumes the snapshot
  and executes the pending operation; rejecting resumes into a deterministic
  approval error.
  """
  @moduledoc @guide

  use Jidoka.Agent

  alias JidokaExample.ApprovalAgent.Controls.RequireRefundApproval

  def guide, do: @guide

  agent :approval_agent do
    instructions """
    You are a careful support operations agent.

    When the user asks for a refund, call issue_refund with order_id, amount,
    and reason. Do not claim the refund was issued until the tool result is
    present. After the tool result, answer with the refund status and approval
    id.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 700}}
  end

  controls do
    max_turns 4
    timeout 30_000

    operation RequireRefundApproval, when: [kind: :action, name: "issue_refund"]
  end

  tools do
    action JidokaExample.ApprovalAgent.Actions.IssueRefund
  end
end
