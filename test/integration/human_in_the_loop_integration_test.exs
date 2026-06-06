defmodule Jidoka.HumanInTheLoopIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2, event_index: 2, operation_capability_index: 2, timeline: 1]

  test "operation interrupt hibernates with a durable approval request" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required,
               approval_ttl_ms: 30_000,
               clock: clock(1_000)
             )

    assert snapshot.cursor.phase == :review
    assert snapshot.cursor.metadata["operation"] == "review_lookup"

    assert %Turn.State{status: :waiting, pending_interrupt: %Review.Interrupt{} = interrupt} =
             snapshot.turn_state

    assert interrupt.boundary == :operation
    assert interrupt.control_name == "operation_decision_control"
    assert interrupt.reason == :approval_required
    assert interrupt.operation == "review_lookup"
    assert interrupt.operation_kind == :operation
    assert interrupt.arguments == %{"id" => "reviewed"}
    assert interrupt.created_at_ms == 1_000
    assert interrupt.expires_at_ms == 31_000

    assert %Review.Request{} = approval_request = snapshot.metadata["pending_review"]
    assert approval_request.interrupt_id == interrupt.id
    assert approval_request.operation == "review_lookup"
    assert approval_request.arguments == %{"id" => "reviewed"}
    assert approval_request.expires_at_ms == 31_000

    timeline = timeline(snapshot.turn_state.events)
    assert Enum.any?(timeline, &match?(%{event: :control_interrupted}, &1))
    assert Enum.any?(timeline, &match?(%{event: :approval_requested}, &1))

    refute Enum.any?(
             timeline,
             &match?(%{event: :capability_call_started, operation: "review_lookup"}, &1)
           )

    assert {:ok, serialized} = AgentSnapshot.serialize(snapshot)

    assert {:ok, %AgentSnapshot{cursor: %{phase: :review}}} =
             AgentSnapshot.deserialize(serialized)

    refute_received {:review_lookup_called, _id}
  end

  test "approval resumes a serialized snapshot and executes the pending operation once" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, clock: clock(2_000))

    interrupt = snapshot.turn_state.pending_interrupt
    approval = Review.Response.approve(interrupt, responded_at_ms: 2_001)
    serialized = AgentSnapshot.serialize!(snapshot)

    assert {:ok, %Turn.Result{content: "reviewed is approved."} = result} =
             Jidoka.resume(serialized,
               approval: approval,
               llm: llm(),
               operations: operations(),
               clock: clock(2_001)
             )

    assert_receive {:review_lookup_called, "reviewed"}

    assert [%Effect.OperationResult{operation: "review_lookup"}] =
             result.agent_state.operation_results

    timeline = timeline(result.events)
    approval_responded_index = event_index(timeline, :approval_responded)
    approval_applied_index = event_index(timeline, :approval_applied)
    capability_index = operation_capability_index(timeline, "review_lookup")

    assert approval_responded_index < approval_applied_index
    assert approval_applied_index < capability_index
  end

  test "resume without approval keeps the review snapshot hibernated" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, clock: clock(3_000))

    assert {:hibernate, %AgentSnapshot{} = same_snapshot} =
             Jidoka.resume(snapshot, llm: llm(), operations: operations())

    assert same_snapshot.snapshot_id == snapshot.snapshot_id
    assert same_snapshot.cursor.phase == :review

    assert same_snapshot.turn_state.pending_interrupt.id ==
             snapshot.turn_state.pending_interrupt.id

    refute_received {:review_lookup_called, _id}
  end

  test "denial resumes to a deterministic approval error without running the operation" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, clock: clock(4_000))

    interrupt = snapshot.turn_state.pending_interrupt
    denial = Review.Response.deny(interrupt, reason: :human_rejected, responded_at_ms: 4_001)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :approval,
              details: %{
                reason: :approval_denied,
                interrupt_id: interrupt_id,
                decision: :denied,
                approval_reason: :human_rejected
              }
            }} = Jidoka.resume(snapshot, approval: denial, llm: llm(), operations: operations())

    assert interrupt_id == interrupt.id
    refute_received {:review_lookup_called, _id}
  end

  test "expired approval fails without running the pending operation" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, approval_ttl_ms: 10, clock: clock(5_000))

    interrupt = snapshot.turn_state.pending_interrupt
    approval = Review.Response.approve(interrupt, responded_at_ms: 5_011)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :approval,
              details: %{
                reason: :approval_expired,
                interrupt_id: interrupt_id,
                responded_at_ms: 5_011,
                expires_at_ms: 5_010
              }
            }} = Jidoka.resume(snapshot, approval: approval, llm: llm(), operations: operations())

    assert interrupt_id == interrupt.id
    refute_received {:review_lookup_called, _id}
  end

  test "invalid approval ttl is rejected before hibernating review state" do
    assert {:error,
            %Jidoka.Error.ValidationError{
              field: :approval_ttl_ms,
              value: 0,
              details: %{reason: :invalid_approval_ttl_ms}
            }} = run_interrupted_turn(:approval_required, approval_ttl_ms: 0, clock: clock(5_000))

    refute_received {:review_lookup_called, _id}
  end

  test "malformed approval response is rejected before resume" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, clock: clock(6_000))

    approval = %{interrupt_id: snapshot.turn_state.pending_interrupt.id, decision: :maybe}

    assert {:error,
            %Jidoka.Error.ValidationError{
              field: :approval,
              details: %{reason: :invalid_approval_response}
            }} = Jidoka.resume(snapshot, approval: approval, llm: llm(), operations: operations())

    refute_received {:review_lookup_called, _id}
  end

  test "approval response must target the pending interrupt" do
    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             run_interrupted_turn(:approval_required, clock: clock(7_000))

    approval = Review.Response.approve("intr:other", responded_at_ms: 7_001)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :approval,
              details: %{
                reason: :approval_interrupt_mismatch,
                expected_interrupt_id: expected,
                actual_interrupt_id: "intr:other"
              }
            }} = Jidoka.resume(snapshot, approval: approval, llm: llm(), operations: operations())

    assert expected == snapshot.turn_state.pending_interrupt.id
    refute_received {:review_lookup_called, _id}
  end

  defp run_interrupted_turn(reason, opts) do
    Jidoka.turn(
      spec(),
      request({:interrupt, reason}),
      [llm: llm(), operations: operations()] ++ opts
    )
  end

  defp spec do
    Agent.Spec.new!(
      id: "hitl_review_agent",
      instructions: "Use review_lookup before answering.",
      model: %{provider: :test, id: "model"},
      operations: [
        Agent.Spec.Operation.new!(
          name: "review_lookup",
          description: "Looks up a value requiring review.",
          idempotency: :idempotent
        )
      ],
      controls: %{
        operations: [
          %{
            control: Jidoka.IntegrationSupport.OperationDecisionControl,
            match: %{kind: :operation, name: "review_lookup"}
          }
        ]
      },
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp request(decision) do
    Turn.Request.new!(
      input: "Look up reviewed",
      metadata: %{
        operation_control_decision: decision
      }
    )
  end

  defp llm do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok, %{type: :operation, name: "review_lookup", arguments: %{"id" => "reviewed"}}}

        1 ->
          {:ok, %{type: :final, content: "reviewed is approved."}}
      end
    end
  end

  defp operations do
    test_pid = self()

    LocalOperations.operations(%{
      "review_lookup" => fn %{"id" => id}, _ctx ->
        send(test_pid, {:review_lookup_called, id})
        {:ok, %{id: id, value: "approved"}}
      end
    })
  end

  defp clock(now_ms), do: fn -> now_ms end
end
