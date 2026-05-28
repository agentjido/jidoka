defmodule JidokaExamples.Workflows.MathWorkflow do
  use Jidoka.Workflow

  workflow do
    id :example_math_workflow
    description "Adds one and doubles the result."
    input Zoi.object(%{value: Zoi.integer()})
  end

  steps do
    action(:add_one, JidokaExamples.Workflows.AddOne, input: %{value: input(:value)})
    action(:double, JidokaExamples.Workflows.DoubleValue, input: from(:add_one))
  end

  output from(:double)
end
