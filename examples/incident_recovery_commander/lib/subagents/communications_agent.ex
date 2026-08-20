defmodule JidokaExamples.IncidentRecoveryCommander.Subagents.CommunicationsAgent do
  @moduledoc false

  use Jidoka.Agent

  alias JidokaExamples.IncidentRecoveryCommander.Actions.PublishStatusUpdate

  agent :incident_communications_specialist do
    model %{provider: :test, id: "incident-communications-scripted"}
    instructions "Draft one status update and publish it only after operator approval."
  end

  tools do
    action(PublishStatusUpdate,
      idempotency: :unsafe_once,
      approval: [reason: :external_incident_message_requires_review]
    )
  end

  controls do
    max_turns 3
    timeout 5_000
  end
end
