defmodule Jidoka.Agent.ControlCompiler do
  @moduledoc false

  alias Jidoka.Agent.Spec.Controls

  @spec compile!(module()) :: Controls.t()
  def compile!(agent_module) when is_atom(agent_module) do
    entities = Spark.Dsl.Extension.get_entities(agent_module, [:controls])

    operations =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.OperationControl{} = control ->
          [
            normalize_dsl_value!(agent_module, [:controls, :operation], fn ->
              Controls.Operation.new!(
                control: control.control,
                match: control.match
              )
            end)
          ]

        _entity ->
          []
      end)

    inputs =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.InputControl{} = input ->
          [
            normalize_dsl_value!(agent_module, [:controls, :input], fn ->
              Controls.Input.new!(
                control: input.control,
                metadata: input.metadata || %{}
              )
            end)
          ]

        _entity ->
          []
      end)

    outputs =
      entities
      |> Enum.flat_map(fn
        %Jidoka.Agent.Dsl.OutputControl{} = output ->
          [
            normalize_dsl_value!(agent_module, [:controls, :output], fn ->
              Controls.Output.new!(
                control: output.control,
                metadata: output.metadata || %{}
              )
            end)
          ]

        _entity ->
          []
      end)

    normalize_dsl_value!(agent_module, [:controls], fn ->
      Controls.new!(
        max_turns: singleton_control_value(entities, Jidoka.Agent.Dsl.MaxTurnsControl),
        timeout_ms: singleton_control_value(entities, Jidoka.Agent.Dsl.TimeoutControl),
        inputs: inputs,
        operations: operations,
        outputs: outputs
      )
    end)
  end

  defp singleton_control_value(entities, entity_module) do
    entities
    |> Enum.filter(&match?(%{__struct__: ^entity_module}, &1))
    |> case do
      [] -> nil
      [%{value: value}] -> value
    end
  end

  defp normalize_dsl_value!(agent_module, path, fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception ->
      reraise Spark.Error.DslError.exception(
                message: Exception.message(exception),
                path: path,
                module: agent_module
              ),
              __STACKTRACE__
  end
end
