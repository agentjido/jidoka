defmodule Jidoka.Parity.ResumableToolApprovalTest do
  use Jidoka.ParityCase, parity: :resumable_tool_approval

  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Snapshot
  alias Jidoka.Adapter.Jido.Actions
  alias Jidoka.Schema
  alias Jidoka.Turn

  import Jidoka.TestSupport,
    only: [count_results: 2, event_index: 2, operation_capability_index: 2, timeline: 1]

  @moduletag :e06

  defmodule IssueRefund do
    @moduledoc false

    alias Jidoka.Schema

    use Jidoka.Action,
      name: "issue_refund",
      description: "Issues a refund after a human approves the pending operation.",
      schema:
        Zoi.object(%{
          order_id: Zoi.string(),
          amount: Zoi.number(),
          reason: Zoi.string()
        })

    @impl true
    def run(params, context) do
      call_counter = Jidoka.Context.get_runtime(context, :call_counter)

      unless is_pid(call_counter) do
        raise "issue_refund requires the runtime-only :call_counter context"
      end

      arguments = %{
        "order_id" => Schema.get_key(params, :order_id),
        "amount" => Schema.get_key(params, :amount),
        "reason" => Schema.get_key(params, :reason)
      }

      Elixir.Agent.update(call_counter, &[arguments | &1])

      {:ok,
       %{
         "refund_id" => "refund_#{arguments["order_id"]}",
         "status" => "issued"
       }}
    end
  end

  defmodule RefundAgent do
    @moduledoc false

    use Jidoka.Agent

    alias Jidoka.Parity.ResumableToolApprovalTest.IssueRefund

    agent :resumable_tool_approval do
      model %{provider: :test, id: "scripted-model"}

      instructions """
      Use issue_refund when a customer requests a refund. Never claim success
      until the operation result is present.
      """
    end

    tools do
      action(IssueRefund,
        idempotency: :unsafe_once,
        approval: [
          reason: :refund_requires_review,
          message: "Review this refund before it is issued.",
          ttl_ms: 30_000,
          metadata: %{"risk" => "financial_side_effect"}
        ]
      )
    end
  end

  test "pauses and resumes a tool call through human approval" do
    {:ok, call_counter} = Elixir.Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(call_counter), do: Elixir.Agent.stop(call_counter) end)

    llm = scripted_llm()
    operations = Actions.operations([IssueRefund])
    reviewed_arguments = reviewed_arguments()

    assert {:hibernate, snapshot} = start_review(llm, call_counter, 1_000)
    assert {:ok, [review]} = Jidoka.pending_reviews(snapshot)

    assert %{
             kind: :snapshot,
             cursor: %{phase: :review},
             pending_review: %{interrupt_id: pending_interrupt_id},
             timeline: snapshot_events
           } = Jidoka.inspect(snapshot)

    assert review.interrupt_id == pending_interrupt_id
    assert review.operation == "issue_refund"
    assert review.arguments == reviewed_arguments
    assert review.reason == :refund_requires_review
    assert review.created_at_ms == 1_000
    assert review.expires_at_ms == 31_000

    assert review.metadata["control_metadata"]["policy"]["message"] ==
             "Review this refund before it is issued."

    assert review.metadata["control_metadata"]["policy"]["metadata"]["risk"] ==
             "financial_side_effect"

    refute Enum.any?(
             snapshot_events,
             &match?(
               %{event: :capability_call_started, operation: "issue_refund"},
               &1
             )
           )

    assert call_count(call_counter) == 0

    assert {:ok, serialized} = Snapshot.serialize(snapshot)
    assert {:ok, ^snapshot} = Snapshot.deserialize(serialized)
    assert snapshot.schema_version == Snapshot.schema_version()

    tampered_serialized = tamper_payload(serialized)

    assert {:error, :invalid_snapshot_signature} =
             Snapshot.deserialize(tampered_serialized)

    assert {:error,
            %ExecutionError{
              phase: :harness,
              details: %{operation: :resume, cause: :invalid_snapshot_signature}
            }} =
             Jidoka.approve(tampered_serialized, review,
               reason: :operator_approved,
               responded_at_ms: 1_001,
               llm: llm,
               operations: operations,
               operation_context: %{call_counter: call_counter},
               clock: clock(1_001)
             )

    assert call_count(call_counter) == 0

    wrong_interrupt_id = review.interrupt_id <> ":wrong-target"

    assert {:error,
            %ExecutionError{
              phase: :approval,
              details: %{
                reason: :approval_interrupt_mismatch,
                expected_interrupt_id: expected_interrupt_id,
                actual_interrupt_id: ^wrong_interrupt_id
              }
            }} =
             Jidoka.approve(serialized, wrong_interrupt_id,
               reason: :operator_approved,
               responded_at_ms: 1_001,
               llm: llm,
               operations: operations,
               operation_context: %{call_counter: call_counter},
               clock: clock(1_001)
             )

    assert expected_interrupt_id == review.interrupt_id
    assert call_count(call_counter) == 0

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.approve(serialized, review,
               reason: :operator_approved,
               responded_at_ms: 1_001,
               llm: llm,
               operations: operations,
               operation_context: %{call_counter: call_counter},
               clock: clock(1_001)
             )

    assert result.content == "Refund refund_A1001 issued."
    assert call_count(call_counter) == 1
    assert executed_arguments(call_counter) == [reviewed_arguments]

    assert [operation_result] = result.agent_state.operation_results
    assert operation_result.operation == "issue_refund"
    assert operation_result.arguments == reviewed_arguments
    assert value(operation_result.output, :refund_id) == "refund_A1001"
    assert value(operation_result.output, :status) == "issued"

    assert [operation_intent] =
             result.journal.intents
             |> Map.values()
             |> Enum.filter(&match?(%Effect.Intent{kind: :operation}, &1))

    assert operation_intent.payload.name == "issue_refund"
    assert operation_intent.payload.arguments == reviewed_arguments
    assert count_results(result.journal, :operation) == 1

    assert %Effect.Result{
             intent_id: operation_intent_id,
             kind: :operation,
             status: :ok,
             output: journal_output
           } = Map.fetch!(result.journal.results, operation_intent.id)

    assert operation_intent_id == operation_intent.id
    assert journal_output == operation_result.output

    events = timeline(result.events)
    approval_requested_index = event_index(events, :approval_requested)
    approval_responded_index = event_index(events, :approval_responded)
    approval_applied_index = event_index(events, :approval_applied)
    capability_started_index = operation_capability_index(events, "issue_refund")

    capability_completed_index =
      Enum.find_index(
        events,
        &match?(
          %{
            event: :capability_call_completed,
            effect_kind: :operation,
            operation: "issue_refund"
          },
          &1
        )
      )

    assert Enum.all?(
             [
               approval_requested_index,
               approval_responded_index,
               approval_applied_index,
               capability_started_index,
               capability_completed_index
             ],
             &is_integer/1
           )

    assert approval_requested_index < approval_responded_index
    assert approval_responded_index < approval_applied_index
    assert approval_applied_index < capability_started_index
    assert capability_started_index < capability_completed_index

    assert Enum.count(
             events,
             &match?(
               %{event: :capability_call_started, effect_kind: :operation, operation: "issue_refund"},
               &1
             )
           ) == 1

    assert Enum.count(
             events,
             &match?(
               %{event: :capability_call_completed, effect_kind: :operation, operation: "issue_refund"},
               &1
             )
           ) == 1

    assert {:hibernate, denied_snapshot} = start_review(llm, call_counter, 2_000)
    assert {:ok, [denied_review]} = Jidoka.pending_reviews(denied_snapshot)
    assert {:ok, denied_serialized} = Snapshot.serialize(denied_snapshot)

    assert {:error,
            %ExecutionError{
              phase: :approval,
              details: %{
                reason: :approval_denied,
                interrupt_id: denied_interrupt_id,
                decision: :denied,
                approval_reason: :operator_rejected
              }
            }} =
             Jidoka.deny(denied_serialized, denied_review,
               reason: :operator_rejected,
               responded_at_ms: 2_001,
               llm: llm,
               operations: operations,
               operation_context: %{call_counter: call_counter},
               clock: clock(2_001)
             )

    assert denied_interrupt_id == denied_review.interrupt_id
    assert call_count(call_counter) == 1
  end

  defp start_review(llm, call_counter, now_ms) do
    RefundAgent.run_turn("Refund order A1001 for 42.50",
      llm: llm,
      operation_context: %{call_counter: call_counter},
      clock: clock(now_ms)
    )
  end

  defp scripted_llm do
    fn %Effect.Intent{kind: :llm, payload: payload}, %Effect.Journal{}, _context ->
      case tool_observation(payload, "issue_refund") do
        nil ->
          {:ok,
           %{
             type: :operation,
             name: "issue_refund",
             arguments: reviewed_arguments()
           }}

        output ->
          refund_id = value(output, :refund_id)
          status = value(output, :status)
          {:ok, %{type: :final, content: "Refund #{refund_id} #{status}."}}
      end
    end
  end

  defp tool_observation(payload, operation) do
    payload
    |> value(:prompt)
    |> value(:messages)
    |> Enum.find_value(fn message ->
      if value(message, :role) == :tool and value(message, :operation) == operation do
        value(message, :output)
      end
    end)
  end

  defp tamper_payload(serialized) do
    {separator_index, 1} = serialized |> :binary.matches(".") |> List.last()
    payload = binary_part(serialized, 0, separator_index)
    signature = binary_part(serialized, separator_index + 1, byte_size(serialized) - separator_index - 1)

    payload_size = byte_size(payload) - 1
    <<payload_prefix::binary-size(^payload_size), last>> = payload
    replacement = if last == ?A, do: ?B, else: ?A
    payload_prefix <> <<replacement>> <> "." <> signature
  end

  defp reviewed_arguments do
    %{
      "order_id" => "A1001",
      "amount" => 42.50,
      "reason" => "duplicate charge"
    }
  end

  defp executed_arguments(counter), do: counter |> Elixir.Agent.get(& &1) |> Enum.reverse()
  defp call_count(counter), do: counter |> executed_arguments() |> length()
  defp clock(now_ms), do: fn -> now_ms end
  defp value(nil, _key), do: nil
  defp value(map, key), do: Schema.get_key(map, key)
end
