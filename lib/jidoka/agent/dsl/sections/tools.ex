defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  @spec action_entity() :: Spark.Dsl.Entity.t()
  def action_entity do
    %Spark.Dsl.Entity{
      name: :action,
      target: Jidoka.Agent.Dsl.Tool,
      args: [:module],
      describe: """
      Register a deterministic action module for this agent.
      """,
      schema: [
        module: [
          type: :atom,
          required: true,
          doc: "A module defined with `use Jidoka.Action` or a compatible Jido action module."
        ]
      ]
    }
  end

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :tools,
      describe: """
      Register model-callable deterministic operations.
      """,
      entities: [action_entity()]
    }
  end
end
