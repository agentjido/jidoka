defmodule Jidoka.Agent.Dsl do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Capabilities, Contract, Legacy, Lifecycle, Memory, Schedules, Tools}

  @contract_section Contract.section()
  @tools_section Tools.section()
  @capabilities_section Capabilities.section()
  @lifecycle_section Lifecycle.section()
  @schedules_section Schedules.section()
  @memory_section Memory.section()
  @legacy_skills_section Legacy.skills_section()
  @legacy_plugins_section Legacy.plugins_section()
  @legacy_subagents_section Legacy.subagents_section()
  @legacy_hooks_section Legacy.hooks_section()
  @legacy_guardrails_section Legacy.guardrails_section()

  use Spark.Dsl.Extension,
    sections: [
      @contract_section,
      @tools_section,
      @capabilities_section,
      @lifecycle_section,
      @schedules_section,
      @memory_section,
      @legacy_skills_section,
      @legacy_subagents_section,
      @legacy_plugins_section,
      @legacy_hooks_section,
      @legacy_guardrails_section
    ],
    verifiers: [
      Jidoka.Agent.Verifiers.VerifyModel,
      Jidoka.Agent.Verifiers.VerifyMemory,
      Jidoka.Agent.Verifiers.VerifyTools,
      Jidoka.Agent.Verifiers.VerifyAshResources,
      Jidoka.Agent.Verifiers.VerifySkills,
      Jidoka.Agent.Verifiers.VerifySubagents,
      Jidoka.Agent.Verifiers.VerifyPlugins,
      Jidoka.Agent.Verifiers.VerifyHooks,
      Jidoka.Agent.Verifiers.VerifyGuardrails
    ]
end
