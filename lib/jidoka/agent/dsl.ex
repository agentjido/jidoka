defmodule Jidoka.Agent.Dsl do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Contract, Controls, Tools}

  @contract_section Contract.section()
  @tools_section Tools.section()
  @controls_section Controls.section()

  use Spark.Dsl.Extension,
    sections: [
      @contract_section,
      @tools_section,
      @controls_section
    ],
    verifiers: [
      Jidoka.Agent.Verifiers.VerifyModel,
      Jidoka.Agent.Verifiers.VerifyTools,
      Jidoka.Agent.Verifiers.VerifyAshResources,
      Jidoka.Agent.Verifiers.VerifySkills,
      Jidoka.Agent.Verifiers.VerifySubagents,
      Jidoka.Agent.Verifiers.VerifyPlugins,
      Jidoka.Agent.Verifiers.VerifyGuardrails
    ]
end
