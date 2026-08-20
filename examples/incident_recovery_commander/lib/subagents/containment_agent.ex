defmodule JidokaExamples.IncidentRecoveryCommander.Subagents.ContainmentAgent do
  @moduledoc false

  use Jidoka.Agent

  alias JidokaExamples.IncidentRecoveryCommander.Actions.IsolateService

  agent :incident_containment_specialist do
    model %{provider: :test, id: "incident-containment-scripted"}
    instructions "Propose one bounded containment change and wait for operator approval."
  end

  tools do
    action(IsolateService,
      idempotency: :unsafe_once,
      approval: [reason: :production_containment_requires_review]
    )
  end

  controls do
    max_turns 3
    timeout 5_000
  end
end
