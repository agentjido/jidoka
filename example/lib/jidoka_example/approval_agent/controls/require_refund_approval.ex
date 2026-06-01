defmodule JidokaExample.ApprovalAgent.Controls.RequireRefundApproval do
  @moduledoc false

  use Jidoka.Control, name: "require_refund_approval"

  @impl true
  def call(%{boundary: :operation, operation: "issue_refund"}) do
    {:interrupt, :approval_required}
  end

  def call(_context), do: :allow
end
