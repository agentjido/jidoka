defmodule JidokaExamples.GettingStarted.Agent do
  @moduledoc """
  The smallest complete Jidoka example agent.

  The agent declares a production model and one instruction. The example
  scenario injects a deterministic model function, so local runs do not need a
  provider key or network access.
  """

  use Jidoka.Agent

  agent :getting_started do
    model "openai:gpt-4o-mini"
    instructions "Answer clearly and briefly."
  end
end
