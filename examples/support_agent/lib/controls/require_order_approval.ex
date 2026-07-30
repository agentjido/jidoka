defmodule JidokaExamples.SupportAgent.Controls.RequireOrderApproval do
  @moduledoc false

  use Jidoka.Control, name: "require_order_approval"

  alias Jidoka.Runtime.Controls.OperationContext

  @impl true
  def call(%OperationContext{operation: "lookup_order", ctx: context, arguments: arguments}) do
    approval_required? = not is_nil(Jidoka.Context.get(context, :credential_ref))

    notify(
      context,
      {:order_control_called, "lookup_order", arguments, approval_required?}
    )

    if approval_required? do
      {:interrupt, :authenticated_order_access}
    else
      :allow
    end
  end

  def call(_operation), do: :allow

  defp notify(context, message) do
    case Jidoka.Context.get_runtime(context, :example_observer) do
      observer when is_pid(observer) -> send(observer, message)
      _observer -> :ok
    end
  end
end
