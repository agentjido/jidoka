defmodule JidokaExample.ApprovalAgent.Actions.IssueRefund do
  @moduledoc false

  use Jidoka.Action,
    name: "issue_refund",
    description: "Issues a support refund after human approval.",
    idempotency: :once,
    schema:
      Zoi.object(%{
        order_id: Zoi.string(),
        amount: Zoi.number(),
        reason: Zoi.string()
      })

  @impl true
  def run(params, _context) do
    {:ok,
     %{
       "approval_id" => Jidoka.Id.random("refund"),
       "status" => "issued",
       "order_id" => get(params, :order_id),
       "amount" => get(params, :amount),
       "reason" => get(params, :reason)
     }}
  end

  defp get(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
