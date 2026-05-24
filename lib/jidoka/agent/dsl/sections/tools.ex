defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.Capabilities

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :tools,
      describe: """
      Register deterministic operations available to this agent.
      """,
      entities: [
        Capabilities.action_entity()
      ]
    }
  end
end
