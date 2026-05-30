defmodule Jidoka.IntegrationSupport.AuditControl do
  @moduledoc false

  use Jidoka.Control, name: "audit_control"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    if pid =
         operation.context[:test_pid] || operation.context["test_pid"] ||
           operation.request_metadata[:test_pid] || operation.request_metadata["test_pid"] do
      send(pid, {:operation_control_called, name(), operation.operation, operation.arguments})
    end

    :cont
  end

  def call(_operation), do: :cont
end
