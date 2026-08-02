defmodule JidokaExamples.DurableRefund.ExecutionAndContinuationTest do
  use ExUnit.Case, async: false

  alias Jidoka.Cancellation
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Event
  alias Jidoka.Harness.SessionLineage
  alias Jidoka.Stream
  alias JidokaExamples.DurableRefund.Scenario

  @moduletag example: :durable_refund
  @moduletag scenario: :execution_and_continuation
  @moduletag timeout: 5_000

  @tag :async_execution
  @tag :event_streaming
  test "streams correlated deltas and one async terminal result" do
    assert {:ok, report} = Scenario.async_streaming(observer: self())
    assert report.answer == "Refund guidance is ready."
    assert report.text == report.answer
    assert report.thinking == "check policy "

    assert [%Event{event: :turn_finished, request_id: request_id}] = report.terminal_events
    assert request_id == report.request_id
    assert Enum.all?(report.events, &(&1.request_id == request_id))
  end

  @tag :cancellation
  test "cancels active model work with typed terminal evidence" do
    assert {:ok,
            %{
              cancellation: %Cancellation{forced?: false, reason: :cancelled},
              capability_alive?: false,
              terminal_events: [%Event{event: :turn_failed} = terminal]
            }} = Scenario.typed_cancellation(observer: self())

    assert Stream.terminal?(terminal)
    assert Event.cancelled?(terminal)
  end

  @tag :execution_budgets
  test "enforces model-turn, token, and capability-time limits" do
    assert {:ok,
            %{
              max_tokens: 64,
              operation_calls: 1,
              turn_result:
                {:error,
                 %ExecutionError{
                   phase: :turn,
                   details: %{reason: :max_model_turns_exceeded, max_model_turns: 1}
                 }},
              timeout_result:
                {:error,
                 %ExecutionError{
                   phase: :effect,
                   details: %{reason: :capability_timeout, timeout_ms: 5}
                 }}
            }} = Scenario.bounded_execution(observer: self())
  end

  @tag :crash_recovery
  test "recovers one durable unsafe result without issuing the refund twice" do
    assert {:ok, report} = Scenario.durable_recovery(observer: self())
    assert report.answer == "Refund refund_A1001 is queued."
    assert report.operation_calls == 1
    assert report.session.status == :finished
    assert report.session.lease == nil

    assert Enum.any?(report.durable_snapshot.turn_state.journal.results, fn {_id, result} ->
             result.kind == :operation
           end)
  end

  @tag :safe_session_fork
  test "runs independent answers from a lineage-aware safe fork" do
    assert {:ok, report} = Scenario.safe_fork()
    assert report.source_answer == "manual review path"
    assert report.branch_answer == "automatic refund path"
    assert report.source.session_id != report.branch.session_id
    assert report.source.lineage == nil

    assert %SessionLineage{
             root_session_id: root_id,
             parent_session_id: parent_id,
             depth: 1
           } = report.branch.lineage

    assert root_id == report.source.session_id
    assert parent_id == report.source.session_id
    assert report.source_before_fork.status == :hibernated
    assert report.branch_before_resume.status == :hibernated
  end
end
