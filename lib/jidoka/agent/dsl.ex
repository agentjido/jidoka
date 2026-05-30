defmodule Jidoka.Agent.Dsl do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Agent, Controls, Tools}

  @agent_section Agent.section()
  @controls_section Controls.section()
  @tools_section Tools.section()

  use Spark.Dsl.Extension,
    sections: [
      @agent_section,
      @controls_section,
      @tools_section
    ],
    verifiers: [
      Jidoka.Agent.Verifiers.VerifyAgent,
      Jidoka.Agent.Verifiers.VerifyControls,
      Jidoka.Agent.Verifiers.VerifyTools
    ]
end
