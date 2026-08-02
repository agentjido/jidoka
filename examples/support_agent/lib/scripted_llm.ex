defmodule JidokaExamples.SupportAgent.ScriptedLLM do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Schema

  @doc """
  Builds a deterministic two-step model function for an operation round trip.

  The first call requests the operation. The next call finds that operation's
  observation in the prompt and returns the content from `:final`.
  """
  def operation_round_trip(opts) do
    opts =
      Keyword.validate!(opts, [
        :operation,
        :arguments,
        :final,
        on_observation: fn _output -> :ok end
      ])

    operation = Keyword.fetch!(opts, :operation)
    arguments = Keyword.fetch!(opts, :arguments)
    final = Keyword.fetch!(opts, :final)
    on_observation = Keyword.fetch!(opts, :on_observation)

    validate_options!(operation, arguments, final, on_observation)

    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      case operation_observation(payload, operation) do
        :missing ->
          {:ok,
           %{
             type: :operation,
             name: operation,
             arguments: arguments
           }}

        {:ok, output} ->
          on_observation.(output)

          {:ok,
           %{
             type: :final,
             content: final.(output)
           }}
      end
    end
  end

  defp validate_options!(operation, arguments, final, on_observation) do
    unless is_binary(operation) and operation != "" do
      raise ArgumentError, ":operation must be a non-empty string"
    end

    unless is_map(arguments), do: raise(ArgumentError, ":arguments must be a map")
    unless is_function(final, 1), do: raise(ArgumentError, ":final must be a one-argument function")

    unless is_function(on_observation, 1) do
      raise ArgumentError, ":on_observation must be a one-argument function"
    end
  end

  defp operation_observation(payload, operation) do
    payload
    |> Schema.get_key(:prompt)
    |> Schema.get_key(:messages)
    |> Enum.find(fn message ->
      Schema.get_key(message, :role) == :tool and
        Schema.get_key(message, :operation) == operation
    end)
    |> case do
      nil -> :missing
      message -> {:ok, Schema.get_key(message, :output)}
    end
  end
end
