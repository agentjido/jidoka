defmodule JidokaExamples.Workflows.MathAgent do
  use Jidoka.Agent

  agent :example_workflow_agent do
    model :fast
    instructions "Use the run_math workflow tool when arithmetic needs deterministic execution."
  end

  tools do
    workflow JidokaExamples.Workflows.MathWorkflow,
      as: :run_math,
      result: :structured
  end
end
