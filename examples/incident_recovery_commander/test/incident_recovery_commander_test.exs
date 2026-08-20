defmodule JidokaExamples.IncidentRecoveryCommanderTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Operation

  alias JidokaExamples.IncidentRecoveryCommander.{
    Agent,
    Scenario,
    ScriptedLLM
  }

  alias JidokaExamples.IncidentRecoveryCommander.Subagents.{
    CommunicationsAgent,
    ContainmentAgent
  }

  @moduletag example: :incident_recovery_commander

  @tag :durable_operation_continuations
  @tag :nested_parallel_subagents
  test "compiles one bounded command surface with explicit safety classes" do
    operations = Agent.spec().operations

    assert Enum.map(operations, & &1.name) == [
             "load_incident_topology",
             "forensics_specialist",
             "containment_specialist",
             "communications_specialist",
             "run_recovery_plan"
           ]

    assert %Operation{idempotency: :reconcile, metadata: %{"source" => "workflow"}} =
             Enum.find(operations, &(&1.name == "run_recovery_plan"))

    assert Enum.count(operations, &(&1.metadata["source"] == "subagent")) == 3

    assert [%Operation{idempotency: :unsafe_once}] = ContainmentAgent.spec().operations
    assert [%Operation{idempotency: :unsafe_once}] = CommunicationsAgent.spec().operations
  end

  @tag :bounded_step_retry
  @tag :data_only_replay
  @tag :disk_backed_session
  @tag :effect_reconciliation
  @tag :model_fallback
  @tag :nested_human_review
  @tag :session_memory
  @tag :snapshot_serialization
  @tag :structured_results
  @tag :trace_redaction
  @tag :unsafe_once_operations
  test "recovers one parallel command across a store restart and two approvals" do
    assert {:ok, report} = Scenario.command()

    assert report.initial.completed_operation_count == 2
    assert report.initial.serialized_snapshot_bytes > 0
    assert report.initial.snapshot.snapshot_id == report.initial.restored_snapshot.snapshot_id

    assert Enum.map(report.initial.continuation_descriptors, & &1["kind"]) |> Enum.sort() ==
             ["subagent", "subagent", "workflow"]

    assert MapSet.new(report.initial.review_operations) ==
             MapSet.new(["isolate_service", "publish_status_update"])

    assert report.store_restart_revision == report.initial.waiting_revision
    assert report.approval_order == ["isolate_service", "publish_status_update"]
    assert report.intermediate_continuation_count == 1

    assert report.counts == %{
             forensic_collections: 1,
             service_isolations: 1,
             status_updates: 1,
             topology_loads: 1
           }

    assert report.operation_names == [
             "load_incident_topology",
             "forensics_specialist",
             "containment_specialist",
             "communications_specialist",
             "run_recovery_plan"
           ]

    assert report.value.status == :resolved
    assert report.value.restored_services == ["payments-api", "checkout-api", "ledger-db"]
    assert report.memory_recalled?

    assert Enum.all?(report.model_attempts, fn attempts ->
             Enum.map(attempts, & &1.model) == [ScriptedLLM.primary(), ScriptedLLM.fallback()] and
               List.last(attempts).winner
           end)

    workflow_result = Enum.find(report.result.agent_state.operation_results, &(&1.operation == "run_recovery_plan"))
    assert workflow_result.output.output.reservation_attempts == 2
    assert length(workflow_result.output.output.created_work) == 3

    assert report.replay.status == :finished
    assert report.replay.pending_reviews == []
    assert report.replay.timeline != []
    assert report.trace.entry_count > 0
    refute report.trace.leaks_secret?
  end

  @tag :event_streaming
  test "streams the final incident brief with one terminal event" do
    assert {:ok, report} = Scenario.stream_brief()

    assert report.thinking == "verify durable evidence "
    assert report.text == report.answer
    assert report.terminal_event_count == 1
  end

  @tag :cancellation
  test "cancels active incident work with typed evidence" do
    assert {:ok, report} = Scenario.cancellation_drill()

    assert report.cancellation.reason == :cancelled
    refute report.cancellation.forced?
    refute report.capability_alive?
    assert report.terminal_event_count == 1
  end
end
