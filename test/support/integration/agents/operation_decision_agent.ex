defmodule Jidoka.IntegrationSupport.OperationDecisionAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :operation_decision_agent do
    model %{provider: :test, id: "model"}
    instructions "Use controlled_lookup before answering controlled lookup questions."
  end

  tools do
    action Jidoka.IntegrationSupport.ControlledLookupAction
  end

  controls do
    operation Jidoka.IntegrationSupport.OperationDecisionControl,
      when: [kind: :action, name: :controlled_lookup]
  end
end
