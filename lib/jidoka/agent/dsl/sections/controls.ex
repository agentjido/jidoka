defmodule Jidoka.Agent.Dsl.Sections.Controls do
  @moduledoc false

  @spec max_turns_entity() :: Spark.Dsl.Entity.t()
  def max_turns_entity do
    %Spark.Dsl.Entity{
      name: :max_turns,
      target: Jidoka.Agent.Dsl.MaxTurnsControl,
      args: [:value],
      describe: """
      Set the maximum number of model turns for a single agent turn.
      """,
      schema: [
        value: [
          type: :pos_integer,
          required: true,
          doc: "Maximum number of LLM calls allowed before the turn fails."
        ]
      ]
    }
  end

  @spec timeout_entity() :: Spark.Dsl.Entity.t()
  def timeout_entity do
    %Spark.Dsl.Entity{
      name: :timeout,
      target: Jidoka.Agent.Dsl.TimeoutControl,
      args: [:value],
      describe: """
      Set the wall-clock timeout in milliseconds for a single agent turn.
      """,
      schema: [
        value: [
          type: :pos_integer,
          required: true,
          doc: "Maximum turn duration in milliseconds."
        ]
      ]
    }
  end

  @spec input_entity() :: Spark.Dsl.Entity.t()
  def input_entity do
    %Spark.Dsl.Entity{
      name: :input,
      target: Jidoka.Agent.Dsl.InputControl,
      args: [:control],
      describe: """
      Register a control that evaluates the turn input before the first model call.
      """,
      schema: [
        control: [
          type: :atom,
          required: true,
          doc: "A module implementing the Jidoka control contract."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional control metadata stored in the agent spec."
        ]
      ]
    }
  end

  @spec output_entity() :: Spark.Dsl.Entity.t()
  def output_entity do
    %Spark.Dsl.Entity{
      name: :output,
      target: Jidoka.Agent.Dsl.OutputControl,
      args: [:control],
      describe: """
      Register a control that evaluates the final output before it is returned.
      """,
      schema: [
        control: [
          type: :atom,
          required: true,
          doc: "A module implementing the Jidoka control contract."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional control metadata stored in the agent spec."
        ]
      ]
    }
  end

  @spec operation_entity() :: Spark.Dsl.Entity.t()
  def operation_entity do
    %Spark.Dsl.Entity{
      name: :operation,
      target: Jidoka.Agent.Dsl.OperationControl,
      args: [:control],
      describe: """
      Register a policy control for model-callable operations.
      """,
      schema: [
        control: [
          type: :atom,
          required: true,
          doc: "A module implementing the Jidoka control contract."
        ],
        when: [
          type: :any,
          required: false,
          as: :match,
          doc: "Optional operation match such as `[kind: :action, name: :lookup_account]`."
        ],
        metadata: [
          type: :map,
          required: false,
          default: %{},
          doc: "Optional control metadata stored in the agent spec."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :controls,
      singleton_entity_keys: [:max_turns, :timeout],
      describe: """
      Configure policy controls around inputs, operations, and outputs.
      """,
      entities: [
        max_turns_entity(),
        timeout_entity(),
        input_entity(),
        operation_entity(),
        output_entity()
      ]
    }
  end
end
