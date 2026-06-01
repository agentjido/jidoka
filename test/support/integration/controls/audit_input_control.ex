defmodule Jidoka.IntegrationSupport.AuditInputControl do
  @moduledoc false

  use Jidoka.Control, name: "audit_input_control"

  @impl true
  def call(%{boundary: :input, input: input} = attrs) do
    context = Map.get(attrs, :context, %{})
    request_metadata = Map.get(attrs, :request_metadata, %{})

    send_observation(test_pid(context, request_metadata), input)

    :allow
  end

  defp send_observation(nil, _input), do: :ok
  defp send_observation(pid, input), do: send(pid, {:input_control_called, input})

  defp test_pid(context, request_metadata) do
    context[:test_pid] || context["test_pid"] || request_metadata[:test_pid] ||
      request_metadata["test_pid"]
  end
end
