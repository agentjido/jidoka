defmodule JidokaExamples.WorkflowComposition.Agent do
  @moduledoc "Agent that exposes the complete fulfillment graph as one operation."

  use Jidoka.Agent

  alias JidokaExamples.WorkflowComposition.FulfillmentWorkflow

  agent :workflow_composition do
    model %{provider: :test, id: "workflow-composition-scripted"}
    instructions "Use fulfill_order for every fulfillment request."
  end

  tools do
    workflow FulfillmentWorkflow,
      as: :fulfill_order,
      async: true,
      max_concurrency: 4,
      forward_context: :public,
      result: :structured
  end
end
