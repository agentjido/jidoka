defmodule JidokaExamples.IncidentRecoveryCommander.Subagents.ForensicsAgent do
  @moduledoc false

  use Jidoka.Agent

  alias JidokaExamples.IncidentRecoveryCommander.Actions.CollectForensicEvidence

  agent :incident_forensics_specialist do
    model %{provider: :test, id: "incident-forensics-scripted"}
    instructions "Collect one bounded evidence set before you report the most likely cause."
  end

  tools do
    action(CollectForensicEvidence, idempotency: :pure)
  end

  controls do
    max_turns 3
    timeout 5_000
  end
end
