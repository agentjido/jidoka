defmodule Jidoka.Agent.Dsl.Sections.Tools do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.Tools.{Core, Orchestration}

  @spec action_entity() :: Spark.Dsl.Entity.t()
  def action_entity, do: Core.action_entity()

  @spec ash_resource_entity() :: Spark.Dsl.Entity.t()
  def ash_resource_entity, do: Core.ash_resource_entity()

  @spec browser_entity() :: Spark.Dsl.Entity.t()
  def browser_entity, do: Core.browser_entity()

  @spec mcp_tools_entity() :: Spark.Dsl.Entity.t()
  def mcp_tools_entity, do: Core.mcp_tools_entity()

  @spec catalog_entity() :: Spark.Dsl.Entity.t()
  def catalog_entity, do: Core.catalog_entity()

  @spec skill_ref_entity() :: Spark.Dsl.Entity.t()
  def skill_ref_entity, do: Orchestration.skill_ref_entity()

  @spec skill_path_entity() :: Spark.Dsl.Entity.t()
  def skill_path_entity, do: Orchestration.skill_path_entity()

  @spec subagent_entity() :: Spark.Dsl.Entity.t()
  def subagent_entity, do: Orchestration.subagent_entity()

  @spec handoff_entity() :: Spark.Dsl.Entity.t()
  def handoff_entity, do: Orchestration.handoff_entity()

  @spec workflow_entity() :: Spark.Dsl.Entity.t()
  def workflow_entity, do: Orchestration.workflow_entity()

  @spec section() :: Spark.Dsl.Section.t()
  def section do
    %Spark.Dsl.Section{
      name: :tools,
      describe: """
      Register model-callable operations and operation sources.
      """,
      entities: [
        action_entity(),
        ash_resource_entity(),
        browser_entity(),
        mcp_tools_entity(),
        catalog_entity(),
        skill_ref_entity(),
        skill_path_entity(),
        subagent_entity(),
        handoff_entity(),
        workflow_entity()
      ]
    }
  end
end
