defmodule JidokaExamples.ActionsControls.RequireApproval do
  use Jidoka.Control, name: "require_approval"

  @impl true
  def call(%Jidoka.Guardrails.Tool{tool_name: tool_name, context: context}) do
    if Map.get(context, :credential_ref) && to_string(tool_name) == "load_ticket" do
      Jidoka.Approval.request("Approve authenticated ticket access.",
        data: %{tool: to_string(tool_name), account_id: context.account_id}
      )
    else
      :cont
    end
  end
end
