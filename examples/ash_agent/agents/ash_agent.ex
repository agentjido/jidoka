defmodule JidokaExamples.Ash.Agent do
  use Jidoka.Agent

  agent :example_ash_agent do
    model :fast
    instructions "Use Ash-generated tools when the user asks to create or list users."
  end

  tools do
    ash_resource JidokaExamples.Ash.User
  end
end
