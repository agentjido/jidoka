defmodule Jidoka.Agent.Verifiers.VerifyControls do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Jidoka.Agent.Spec.Controls.Operation

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:controls])
    |> Enum.reduce_while({:ok, MapSet.new()}, fn %Jidoka.Agent.Dsl.OperationControl{} =
                                                   control_ref,
                                                 {:ok, seen} ->
      case Operation.new(control: control_ref.control, match: control_ref.match) do
        {:ok, operation} ->
          duplicate_key = {operation.control, operation.match}

          if MapSet.member?(seen, duplicate_key) do
            {:halt,
             {:error,
              dsl_error(
                "operation control #{inspect(operation.control)} is defined more than once for #{inspect(operation.match)}",
                module,
                [:controls, :operation],
                control_ref
              )}}
          else
            {:cont, {:ok, MapSet.put(seen, duplicate_key)}}
          end

        {:error, message} when is_binary(message) ->
          {:halt, {:error, dsl_error(message, module, [:controls, :operation], control_ref)}}

        {:error, reason} ->
          {:halt,
           {:error,
            dsl_error(
              "invalid operation control: #{inspect(reason)}",
              module,
              [:controls, :operation],
              control_ref
            )}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp dsl_error(message, module, path, entity) do
    Spark.Error.DslError.exception(
      message: message,
      path: path,
      module: module,
      location: Spark.Dsl.Entity.anno(entity)
    )
  end
end
