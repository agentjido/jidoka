defmodule JidokaExamples.Debugging.DebugAgent do
  use Jidoka.Agent

  agent :example_debug_agent do
    model :fast
    instructions "This agent is used to show request inspection, prompt preflight, and tracing."
  end
end
