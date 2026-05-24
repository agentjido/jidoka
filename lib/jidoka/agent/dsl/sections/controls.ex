defmodule Jidoka.Agent.Dsl.Sections.Controls do
  @moduledoc false

  alias Jidoka.Agent.Dsl.{InputGuardrail, OutputGuardrail, ToolGuardrail}

  @spec input_entity() :: Spark.Dsl.Entity.t()
  def input_entity do
    %Spark.Dsl.Entity{
      name: :input,
      describe: """
      Register a control that validates or interrupts the turn input.
      """,
      target: InputGuardrail,
      args: [:guardrail],
      schema: [
        guardrail: [
          type: :any,
          required: true,
          doc: "A Jidoka.Guardrail module or MFA tuple."
        ]
      ]
    }
  end

  @spec result_entity() :: Spark.Dsl.Entity.t()
  def result_entity do
    %Spark.Dsl.Entity{
      name: :result,
      describe: """
      Register a control that validates or interrupts the final agent result.
      """,
      target: OutputGuardrail,
      args: [:guardrail],
      schema: [
        guardrail: [
          type: :any,
          required: true,
          doc: "A Jidoka.Guardrail module or MFA tuple."
        ]
      ]
    }
  end

  @spec operation_entity() :: Spark.Dsl.Entity.t()
  def operation_entity do
    %Spark.Dsl.Entity{
      name: :operation,
      describe: """
      Register a control that validates or interrupts an agent operation.
      """,
      target: ToolGuardrail,
      args: [:guardrail],
      schema: [
        guardrail: [
          type: :any,
          required: true,
          doc: "A Jidoka.Guardrail module or MFA tuple."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :controls,
      describe: """
      Configure policy controls around inputs, operations, and results.
      """,
      entities: [
        input_entity(),
        operation_entity(),
        result_entity()
      ]
    }
  end
end
