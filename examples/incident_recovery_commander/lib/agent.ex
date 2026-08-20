defmodule JidokaExamples.IncidentRecoveryCommander.Agent do
  @moduledoc "A durable incident commander that coordinates reviewed recovery work."

  use Jidoka.Agent

  alias JidokaExamples.IncidentRecoveryCommander.Actions.LoadIncidentTopology

  alias JidokaExamples.IncidentRecoveryCommander.Subagents.{
    CommunicationsAgent,
    ContainmentAgent,
    ForensicsAgent
  }

  alias JidokaExamples.IncidentRecoveryCommander.Workflows.RecoveryWorkflow

  @context_schema Zoi.object(%{
                    incident_id: Zoi.string(),
                    pause_recovery: Zoi.boolean(),
                    region: Zoi.string(),
                    severity: Zoi.enum([:sev1, :sev2]),
                    tenant_id: Zoi.string()
                  })

  @result_schema Zoi.object(%{
                   incident_id: Zoi.string(),
                   isolated_services: Zoi.array(Zoi.string()),
                   restored_services: Zoi.array(Zoi.string()),
                   status: Zoi.enum([:resolved]),
                   summary: Zoi.string()
                 })

  agent :durable_incident_recovery_commander do
    model %{provider: :test, id: "incident-commander-scripted"}
    generation %{temperature: 0.0, max_tokens: 500}

    instructions """
    Coordinate independent incident specialists in parallel. Require operator
    approval for production changes and public messages. Use the deterministic
    recovery workflow. Report resolution only after every operation completes.
    """

    context @context_schema
    memory scope: :session, capture: :manual, max_entries: 4
    result schema: @result_schema, max_repairs: 1
  end

  tools do
    action(LoadIncidentTopology, idempotency: :pure)

    subagent ForensicsAgent,
      as: :forensics_specialist,
      forward_context: {:only, [:incident_id, :region, :severity, :tenant_id]},
      result: :structured

    subagent ContainmentAgent,
      as: :containment_specialist,
      forward_context: {:only, [:incident_id, :region, :severity, :tenant_id]},
      result: :structured

    subagent CommunicationsAgent,
      as: :communications_specialist,
      forward_context: {:only, [:incident_id, :region, :severity, :tenant_id]},
      result: :structured

    workflow RecoveryWorkflow,
      as: :run_recovery_plan,
      async: true,
      max_concurrency: 4,
      forward_context: {:only, [:pause_recovery]},
      result: :structured,
      idempotency: :reconcile
  end

  controls do
    max_turns 4
    timeout 20_000
  end
end
