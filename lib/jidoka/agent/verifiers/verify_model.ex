defmodule Jidoka.Agent.Verifiers.VerifyModel do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    model =
      dsl_state
      |> Spark.Dsl.Verifier.get_entities([:jidoka])
      |> Enum.find_value(:fast, fn
        %Jidoka.Agent.Dsl.Agent{model: model} when not is_nil(model) -> model
        _ -> nil
      end)

    case validate_model(model) do
      :ok ->
        :ok

      {:error, message} ->
        {:error,
         Spark.Error.DslError.exception(
           message: message,
           path: [:agent, :model],
           module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module)
         )}
    end
  end

  defp validate_model(model) do
    Jidoka.Model.model(model)
    :ok
  rescue
    error in [ArgumentError] ->
      {:error, Exception.message(error)}
  end
end
