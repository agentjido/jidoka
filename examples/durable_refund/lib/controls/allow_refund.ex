defmodule JidokaExamples.DurableRefund.Controls.AllowRefund do
  @moduledoc false

  use Jidoka.Control, name: "allow_refund"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{operation: "issue_refund"}), do: :allow
  def call(_operation), do: :allow
end
