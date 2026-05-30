defmodule Jidoka.IntegrationSupport.AuditInputControl do
  @moduledoc false

  use Jidoka.Control, name: "audit_input_control"

  @impl true
  def call(%{boundary: :input, input: input} = attrs) do
    context = Map.get(attrs, :context, %{})
    request_metadata = Map.get(attrs, :request_metadata, %{})

    if pid =
         context[:test_pid] || context["test_pid"] || request_metadata[:test_pid] ||
           request_metadata["test_pid"] do
      send(pid, {:input_control_called, input})
    end

    :allow
  end
end
