defmodule JidokaExamples.WorkflowComposition.DraftAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :fulfillment_draft_agent do
    model %{provider: :test, id: "workflow-agent-node"}
    instructions "Draft one concise fulfillment update."
  end
end

defmodule JidokaExamples.WorkflowComposition.ReviewAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :fulfillment_review_agent do
    model %{provider: :test, id: "workflow-agent-node"}
    instructions "Review one fulfillment update and return the approved text."
  end
end

defmodule JidokaExamples.WorkflowComposition.StaticMultiAgentWorkflow do
  @moduledoc "Static, bounded agent-node workflow used to show the current multi-agent graph boundary."

  use Jidoka.Workflow

  alias JidokaExamples.WorkflowComposition.{DraftAgent, ReviewAgent}

  workflow do
    id :static_fulfillment_agents
    description "Runs a draft agent and review agent through deterministic graph edges."
    input Zoi.object(%{order_id: Zoi.string()})
  end

  steps do
    agent(:draft, DraftAgent,
      prompt: input(:order_id),
      context: %{stage: value(:draft)}
    )

    agent(:review, ReviewAgent,
      prompt: from(:draft),
      context: %{stage: value(:review)}
    )
  end

  output from(:review)
end
