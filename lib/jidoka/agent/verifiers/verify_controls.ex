defmodule Jidoka.Agent.Verifiers.VerifyControls do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Jidoka.Agent.Spec.Controls.{Input, Operation, Output}

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Spark.Dsl.Verifier.get_entities([:controls])
    |> Enum.reduce_while(
      {:ok, %{inputs: MapSet.new(), operations: MapSet.new(), outputs: MapSet.new()}},
      fn
        %Jidoka.Agent.Dsl.InputControl{} = control_ref, {:ok, seen} ->
          verify_boundary(module, control_ref, seen, Input, :inputs, [:controls, :input])

        %Jidoka.Agent.Dsl.OperationControl{} = control_ref, {:ok, seen} ->
          verify_operation(module, control_ref, seen)

        %Jidoka.Agent.Dsl.OutputControl{} = control_ref, {:ok, seen} ->
          verify_boundary(module, control_ref, seen, Output, :outputs, [:controls, :output])

        _entity, {:ok, seen} ->
          {:cont, {:ok, seen}}
      end
    )
    |> case do
      {:ok, _seen} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp verify_boundary(module, control_ref, seen, spec_module, seen_key, path) do
    case spec_module.new(
           control: control_ref.control,
           metadata: control_ref.metadata || %{}
         ) do
      {:ok, boundary_control} ->
        duplicate_key = boundary_control.control

        if MapSet.member?(Map.fetch!(seen, seen_key), duplicate_key) do
          {:halt,
           {:error,
            dsl_error(
              "#{boundary_name(path)} control #{inspect(boundary_control.control)} is defined more than once",
              module,
              path,
              control_ref
            )}}
        else
          {:cont, {:ok, Map.update!(seen, seen_key, &MapSet.put(&1, duplicate_key))}}
        end

      {:error, message} when is_binary(message) ->
        {:halt, {:error, dsl_error(message, module, path, control_ref)}}

      {:error, reason} ->
        {:halt,
         {:error,
          dsl_error(
            "invalid #{boundary_name(path)} control: #{inspect(reason)}",
            module,
            path,
            control_ref
          )}}
    end
  end

  defp boundary_name([:controls, boundary]), do: Atom.to_string(boundary)

  defp verify_operation(module, control_ref, seen) do
    case Operation.new(control: control_ref.control, match: control_ref.match) do
      {:ok, operation} ->
        duplicate_key = {operation.control, operation.match}

        if MapSet.member?(seen.operations, duplicate_key) do
          {:halt,
           {:error,
            dsl_error(
              "operation control #{inspect(operation.control)} is defined more than once for #{inspect(operation.match)}",
              module,
              [:controls, :operation],
              control_ref
            )}}
        else
          {:cont, {:ok, %{seen | operations: MapSet.put(seen.operations, duplicate_key)}}}
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
