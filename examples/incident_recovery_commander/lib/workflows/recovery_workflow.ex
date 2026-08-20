defmodule JidokaExamples.IncidentRecoveryCommander.Workflows.RecoveryWorkflow do
  @moduledoc false

  use Jidoka.Workflow

  alias JidokaExamples.IncidentRecoveryCommander.Workflows.Functions

  workflow do
    id :incident_recovery_plan
    description "Ranks affected services, reserves capacity, and restores each service."

    input Zoi.object(%{
            incident_id: Zoi.string(),
            services: Zoi.array(Zoi.string())
          })
  end

  steps do
    function :validate, {Functions, :validate, 2},
      input: %{
        incident_id: input(:incident_id),
        services: input(:services)
      }

    map :assess_services,
      over: from(:validate, :services),
      function: {Functions, :assess_service, 2},
      input: %{index: index(), service: item()},
      max_concurrency: 3

    reduce :rank_services,
      over: from(:assess_services),
      using: {Functions, :rank_services, 2},
      input: %{
        assessments: items(),
        incident_id: from(:validate, :incident_id)
      }

    function :reserve_capacity, {Functions, :reserve_capacity, 2},
      input: from(:rank_services),
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 0, max: 0]]

    loop(:restart_services,
      initial: %{
        checkpointed: value(false),
        pending: from(:reserve_capacity, :services),
        restored: value([])
      },
      using: {Functions, :restart_next, 2},
      input: %{state: loop_state()},
      max_iterations: 6
    )

    function :finalize, {Functions, :finalize, 2},
      input: %{
        recovery: from(:restart_services),
        reservation: from(:reserve_capacity)
      }
  end

  output from(:finalize)
end
