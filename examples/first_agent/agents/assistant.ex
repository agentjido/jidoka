defmodule JidokaExamples.FirstAgent.Assistant do
  use Jidoka.Agent

  agent :example_first_agent do
    model :fast
    instructions "Answer clearly and concisely. Keep responses under three sentences."
  end
end
