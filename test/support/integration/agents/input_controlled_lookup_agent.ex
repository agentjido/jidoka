defmodule Jidoka.IntegrationSupport.InputControlledLookupAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :input_controlled_lookup_agent do
    model %{provider: :test, id: "model"}
    instructions "Use controlled_lookup before answering controlled lookup questions."
  end

  tools do
    action Jidoka.IntegrationSupport.ControlledLookupAction
  end

  controls do
    max_turns 3
    timeout 1_000

    input Jidoka.IntegrationSupport.AuditInputControl
    input Jidoka.IntegrationSupport.BlockInputControl
  end
end
