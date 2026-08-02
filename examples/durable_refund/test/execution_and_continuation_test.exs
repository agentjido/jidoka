defmodule JidokaExamples.DurableRefund.ExecutionAndContinuationTest do
  use ExUnit.Case, async: false

  alias Jidoka.Cancellation
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Event
  alias Jidoka.Session.Lineage
  alias Jidoka.Stream
  alias JidokaExamples.DurableRefund.Scenario

  @moduletag example: :durable_refund
  @moduletag scenario: :execution_and_continuation
  @moduletag timeout: 5_000

  describe "application behavior" do
    test "runs all six durable refund demonstrations" do
      assert {:ok, report} = Scenario.run([])

      assert report.async_streaming.answer == "Refund guidance is ready."
      assert report.parallel_operations.completion_order == ["B2002", "A1001"]
      assert report.parallel_operations.observation_order == ["A1001", "B2002"]
      assert report.cancellation.reason == :cancelled
      assert report.execution_limits.max_tokens == 64
      assert report.execution_limits.operation_calls == 1
      assert report.durable_recovery.operation_calls == 1
      assert report.durable_recovery.status == :finished
      assert report.safe_fork.source_answer == "manual review path"
      assert report.safe_fork.branch_answer == "automatic refund path"
      assert report.safe_fork.lineage.depth == 1
      assert report.safe_fork.replay_status == :finished
      assert report.safe_fork.replay_event_count > 0
      assert report.observability.usage.total_tokens == 41
      assert report.observability.trace_entries > 0
      assert report.process_host.answer == "The supervised refund agent is ready."
      assert report.process_host.status == :completed
    end
  end

  describe "runtime invariants" do
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

    @tag :parallel_tool_calling
    test "runs independent operations concurrently and observes them in model order" do
      assert {:ok, report} = Scenario.parallel_operations(observer: self())

      assert report.answer == "Both refund policies are eligible."
      assert report.completion_order == ["B2002", "A1001"]
      assert report.observation_order == ["A1001", "B2002"]

      assert Enum.map(report.operations, & &1.output["order_id"]) == ["A1001", "B2002"]
      assert Enum.all?(report.operations, &(&1.operation == "check_refund_policy"))
      assert Enum.all?(report.operations, & &1.output["eligible"])
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
    @tag :effect_idempotency
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
    @tag :checkpoint_state
    @tag :data_only_replay
    test "runs independent answers from a lineage-aware safe fork" do
      assert {:ok, report} = Scenario.safe_fork()
      assert report.source_answer == "manual review path"
      assert report.branch_answer == "automatic refund path"
      assert report.source.session_id != report.branch.session_id
      assert report.source.lineage == nil

      assert %Lineage{
               root_session_id: root_id,
               parent_session_id: parent_id,
               depth: 1
             } = report.branch.lineage

      assert root_id == report.source.session_id
      assert parent_id == report.source.session_id
      assert report.source_before_fork.status == :hibernated
      assert report.branch_before_resume.status == :hibernated
      assert report.source_replay.session_id == report.source.session_id
      assert report.source_replay.status == :finished
      assert report.source_replay.result.content == report.source_answer
      assert report.source_replay.timeline != []
    end

    @tag :local_trace_sink
    @tag :trace_redaction
    @tag :usage_accounting
    test "records redacted local traces and aggregates model usage" do
      assert {:ok, report} = Scenario.observability()

      assert report.result.content == "Order A1001 is eligible for the standard refund."
      assert report.usage.llm_calls == 2
      assert report.usage.input_tokens == 30
      assert report.usage.output_tokens == 11
      assert report.usage.total_tokens == 41
      assert_in_delta report.usage.total_cost, 0.003, 1.0e-9

      sensitive =
        Enum.find(report.trace, fn entry ->
          entry.event == :prompt_assembled and Map.has_key?(Map.get(entry, :data, %{}), :api_key)
        end)

      assert sensitive.data.api_key == "[REDACTED]"
      assert sensitive.data.visible.token == "[REDACTED]"
      assert sensitive.data.visible.operation == "check_refund_policy"
      refute Map.has_key?(sensitive.data, :prompt)
      refute inspect(report.trace) =~ "example-secret-key"
      refute inspect(report.trace) =~ "raw prompt omitted before export"
      refute inspect(report.trace) =~ "example-token"
    end

    @tag :process_hosted_agent
    test "runs the same agent through a supervised process host" do
      assert {:ok, report} = Scenario.process_host()

      assert report.result.content == "The supervised refund agent is ready."
      assert report.terminal.status == :completed
      assert report.terminal.result == report.result.content
      assert is_pid(report.pid)
      assert Jidoka.whereis(report.id) == nil
    end
  end
end
