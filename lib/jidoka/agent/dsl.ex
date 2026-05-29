defmodule Jidoka.Agent.Dsl do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Sections.{Agent, Tools}

  @agent_section Agent.section()
  @tools_section Tools.section()

  use Spark.Dsl.Extension,
    sections: [
      @agent_section,
      @tools_section
    ],
    verifiers: [
      Jidoka.Agent.Verifiers.VerifyAgent,
      Jidoka.Agent.Verifiers.VerifyTools
    ]
end
