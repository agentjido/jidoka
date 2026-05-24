defmodule Jidoka.Agent.Dsl do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Capabilities, Contract, Controls, Lifecycle, Schedules, Tools}

  @contract_section Contract.section()
  @tools_section Tools.section()
  @controls_section Controls.section()
  @capabilities_section Capabilities.section()
  @lifecycle_section Lifecycle.section()
  @schedules_section Schedules.section()

  use Spark.Dsl.Extension,
    sections: [
      @contract_section,
      @tools_section,
      @controls_section,
      @capabilities_section,
      @lifecycle_section,
      @schedules_section
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
