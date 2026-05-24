defmodule Jidoka.Agent.Dsl.Sections.Legacy do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Capabilities, Lifecycle}

  @spec skills_section() :: Spark.Dsl.Section.t()
  def skills_section do
    %Spark.Dsl.Section{
      name: :skills,
      describe: """
      Legacy skill section. Use capabilities instead.
      """,
      entities: [Capabilities.skill_ref_entity(), Capabilities.skill_path_entity()]
    }
  end

  @spec plugins_section() :: Spark.Dsl.Section.t()
  def plugins_section do
    %Spark.Dsl.Section{
      name: :plugins,
      describe: """
      Legacy plugin section. Use capabilities instead.
      """,
      entities: [Capabilities.plugin_entity()]
    }
  end

  @spec subagents_section() :: Spark.Dsl.Section.t()
  def subagents_section do
    %Spark.Dsl.Section{
      name: :subagents,
      describe: """
      Legacy subagent section. Use capabilities instead.
      """,
      entities: [Capabilities.subagent_entity()]
    }
  end

  @spec hooks_section() :: Spark.Dsl.Section.t()
  def hooks_section do
    %Spark.Dsl.Section{
      name: :hooks,
      describe: """
      Legacy hook section. Use lifecycle instead.
      """,
      entities: [
        Lifecycle.before_turn_hook_entity(),
        Lifecycle.after_turn_hook_entity(),
        Lifecycle.interrupt_hook_entity()
      ]
    }
  end

  @spec guardrails_section() :: Spark.Dsl.Section.t()
  def guardrails_section do
    %Spark.Dsl.Section{
      name: :guardrails,
      describe: """
      Legacy guardrail section. Use lifecycle instead.
      """,
      entities: [
        Lifecycle.legacy_input_guardrail_entity(),
        Lifecycle.legacy_output_guardrail_entity(),
        Lifecycle.legacy_tool_guardrail_entity()
      ]
    }
  end
end
