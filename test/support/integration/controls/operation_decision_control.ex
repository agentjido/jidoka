defmodule Jidoka.IntegrationSupport.OperationDecisionControl do
  @moduledoc false

  use Jidoka.Control, name: "operation_decision_control"

  @impl true
  def call(%Jidoka.Runtime.Controls.OperationContext{} = operation) do
    send_observation(operation)

    operation
    |> configured_decision()
    |> resolve_decision()
  end

  defp send_observation(operation) do
    case test_pid(operation) do
      nil -> :ok
      pid -> send(pid, {:operation_decision_control_called, context_observation(operation)})
    end
  end

  defp test_pid(operation) do
    operation.context[:test_pid] || operation.context["test_pid"] ||
      operation.request_metadata[:test_pid] || operation.request_metadata["test_pid"]
  end

  defp context_observation(operation) do
    %{
      arguments: operation.arguments,
      boundary: operation.boundary,
      control_name: operation.control_name,
      idempotency: operation.idempotency,
      idempotency_key?: is_binary(operation.idempotency_key),
      kind: operation.kind,
      operation: operation.operation,
      operation_kind: operation.operation_kind,
      operation_match: operation.operation_match,
      operation_spec: operation_spec_name(operation.operation_spec),
      type: operation.type
    }
  end

  defp operation_spec_name(%{name: name}), do: name
  defp operation_spec_name(_operation_spec), do: nil

  defp configured_decision(operation) do
    operation.request_metadata[:operation_control_decision] ||
      operation.request_metadata["operation_control_decision"] ||
      operation.context[:operation_control_decision] ||
      operation.context["operation_control_decision"] ||
      :cont
  end

  defp resolve_decision(:raise), do: raise("operation control raised")
  defp resolve_decision({:raise, message}) when is_binary(message), do: raise(message)
  defp resolve_decision(decision), do: decision
end
