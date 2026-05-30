defmodule Jidoka.IntegrationSupport.ControlledLookupAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :controlled_lookup_agent do
    model %{provider: :test, id: "model"}
    instructions "Use controlled_lookup before answering controlled lookup questions."
  end

  tools do
    action Jidoka.IntegrationSupport.ControlledLookupAction
  end

  controls do
    operation Jidoka.IntegrationSupport.ApprovalControl,
      when: [kind: :action, name: :controlled_lookup]

    operation Jidoka.IntegrationSupport.AuditControl
  end
end
