defmodule Jidoka.IntegrationSupport.ApprovalControl do
  @moduledoc false

  use Jidoka.Control, name: "require_approval"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    send_observation(operation)

    :cont
  end

  def call(_operation), do: :cont

  defp send_observation(operation) do
    case test_pid(operation) do
      nil -> :ok
      pid -> send(pid, {:operation_control_called, name(), operation.operation, operation.arguments})
    end
  end

  defp test_pid(operation) do
    operation.context[:test_pid] || operation.context["test_pid"] ||
      operation.request_metadata[:test_pid] || operation.request_metadata["test_pid"]
  end
end
