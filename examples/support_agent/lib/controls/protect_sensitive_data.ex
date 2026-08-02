defmodule JidokaExamples.SupportAgent.Controls.ProtectSensitiveData do
  @moduledoc false

  use Jidoka.Control, name: "protect_sensitive_data"

  @sensitive_markers ["api_key", "authorization:", "credential:", "password:", "secret:"]

  @impl true
  def call(%{boundary: :input, input: input}) when is_binary(input) do
    decide(input, :sensitive_input)
  end

  def call(%{boundary: :output, result: result}) when is_binary(result) do
    decide(result, :sensitive_output)
  end

  def call(_context), do: :cont

  defp decide(value, reason) do
    normalized = String.downcase(value)

    if Enum.any?(@sensitive_markers, &String.contains?(normalized, &1)) do
      {:block, reason}
    else
      :cont
    end
  end
end
