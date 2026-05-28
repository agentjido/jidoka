defmodule Jidoka.Agent.Verifiers.VerifyAshResources do
  @moduledoc false

  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    Spark.Dsl.Verifier.get_entities(dsl_state, [:tools])
    |> Enum.filter(&match?(%Jidoka.Agent.Dsl.AshResource{}, &1))
    |> Enum.reduce_while(:ok, fn ash_resource_ref, :ok ->
      case Jidoka.Agent.AshResources.validate_resource(ash_resource_ref.resource) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt, {:error, resource_error(dsl_state, ash_resource_ref, message)}}
      end
    end)
  end

  defp resource_error(dsl_state, ash_resource_ref, message) do
    Spark.Error.DslError.exception(
      message: message,
      path: [:tools, :ash_resource],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: Spark.Dsl.Entity.anno(ash_resource_ref)
    )
  end
end
