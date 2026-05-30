defmodule Jidoka.Agent.Dsl.Sections.Controls do
  @moduledoc false

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
      entities: [operation_entity()]
    }
  end
end
