defmodule JidokaExamples.SupportAgent.ControlledToolCallTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias JidokaExamples.SupportAgent.Agent
  alias JidokaExamples.SupportAgent.Scenario

  @moduletag example: :support_agent
  @moduletag scenario: :controlled_tool_call
  @moduletag timeout: 5_000

  describe "application behavior" do
    test "answers one order request through the public scenario" do
      assert {:ok, %{answer: answer, operations: [operation]}} = Scenario.run([])

      assert answer =~ "Order A1001 is in transit with UPS."
      assert operation.operation == "lookup_order"
      assert operation.arguments == %{"order_id" => "A1001"}
      assert operation.output["status"] == "in_transit"
    end
  end

  describe "runtime invariants" do
    @tag :tool_calling
    @tag :operation_control
    @tag :tool_observation
    test "returns a tool observation through the controlled operation path" do
      {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

      assert Agent.spec().id == "support_agent"

      assert {:ok, %Turn.Result{} = result} =
               Scenario.execute(observer: self(), counter: counter)

      assert_receive {:order_control_called, "lookup_order", control_arguments, false}
      assert control_arguments == %{"order_id" => "A1001"}
      assert_receive {:lookup_order_called, "A1001"}
      assert_receive {:order_observation_seen, observation}
      assert Elixir.Agent.get(counter, & &1) == 1

      assert observation == expected_order()

      assert result.content ==
               "Order A1001 is in transit with UPS. ETA: the next business day. " <>
                 "Tell the customer the package is on schedule and ask them to watch for delivery updates."

      assert [%Effect.OperationResult{} = operation_result] = result.agent_state.operation_results
      assert operation_result.operation == "lookup_order"
      assert operation_result.arguments == %{"order_id" => "A1001"}
      assert operation_result.output == observation
      assert [operation_intent] = journal_intents(result, :operation)
      assert operation_result.effect_id == operation_intent.id
      assert operation_result.request_id == result.metadata.debug.request_id
      assert result.journal.results[operation_intent.id].intent_id == operation_intent.id
      assert result.journal.results[operation_intent.id].output == observation
      assert count_results(result.journal, :llm) == 2
      assert count_results(result.journal, :operation) == 1

      assert_ordered([
        event_index(result.events, :control_allowed, [
          {:operation, "lookup_order"},
          {[:data, :control], "require_order_approval"}
        ]),
        event_index(result.events, :capability_call_started,
          effect_kind: :operation,
          operation: "lookup_order"
        ),
        event_index(result.events, :operation_observed, operation: "lookup_order"),
        event_index(result.events, :prompt_assembled, loop_index: 1),
        event_index(result.events, :turn_finished)
      ])
    end

    @tag :operation_control
    @tag :human_review
    @tag :snapshot_resume
    @tag :serializable_pause_resume
    test "resumes one interrupted operation after approval" do
      {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

      assert {:hibernate, snapshot} =
               Scenario.execute(
                 observer: self(),
                 counter: counter,
                 credential_ref: "credential:support-demo"
               )

      assert_receive {:order_control_called, "lookup_order", %{"order_id" => "A1001"}, true}
      assert Elixir.Agent.get(counter, & &1) == 0
      assert snapshot.turn_state.agent_state.operation_results == []
      assert count_results(snapshot.turn_state.journal, :operation) == 0

      assert [pending_operation] =
               Enum.filter(snapshot.turn_state.pending_effects, &(&1.kind == :operation))

      assert {:ok, [review]} = Jidoka.pending_reviews(snapshot)
      assert review.operation == "lookup_order"
      assert review.arguments == %{"order_id" => "A1001"}
      assert review.reason == :authenticated_order_access

      assert {:ok, serialized} = Snapshot.serialize(snapshot)
      assert {:ok, %Snapshot{} = restored} = Snapshot.deserialize(serialized)
      assert restored == snapshot

      assert {:ok, %Turn.Result{} = result} =
               Scenario.approve(serialized, review,
                 observer: self(),
                 counter: counter
               )

      assert_receive {:lookup_order_called, "A1001"}
      assert_receive {:order_observation_seen, observation}
      assert Elixir.Agent.get(counter, & &1) == 1
      assert observation == expected_order()
      assert [operation_result] = result.agent_state.operation_results
      assert operation_result.output == observation
      assert operation_result.effect_id == pending_operation.id
      assert result.journal.results[pending_operation.id].intent_id == pending_operation.id
      assert count_results(result.journal, :operation) == 1
      assert String.starts_with?(result.content, "Order A1001 is in transit with UPS.")

      assert_ordered([
        event_index(result.events, :control_interrupted, operation: "lookup_order"),
        event_index(result.events, :approval_requested, operation: "lookup_order"),
        event_index(result.events, :turn_hibernated),
        event_index(result.events, :approval_responded, operation: "lookup_order"),
        event_index(result.events, :approval_applied, operation: "lookup_order"),
        event_index(result.events, :capability_call_started,
          effect_kind: :operation,
          operation: "lookup_order"
        ),
        event_index(result.events, :operation_observed, operation: "lookup_order"),
        event_index(result.events, :prompt_assembled, loop_index: 1),
        event_index(result.events, :turn_finished)
      ])
    end

    @tag :serializable_pause_resume
    test "packages the complete serialized review continuation as one scenario" do
      assert {:ok, report} = Scenario.review_and_resume(observer: self())

      assert report.answer =~ "Order A1001 is in transit with UPS."
      assert report.operation_calls == 1
      assert report.review.operation == "lookup_order"
      assert report.schema_version == Snapshot.schema_version()
      assert report.serialized_bytes > 0
    end

    @tag :tool_observation
    test "preserves a not-found operation result for the next model input" do
      {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

      assert {:ok, %Turn.Result{} = result} =
               Scenario.execute(order_id: " z9999 ", observer: self(), counter: counter)

      assert_receive {:lookup_order_called, "Z9999"}
      assert_receive {:order_observation_seen, observation}
      assert Elixir.Agent.get(counter, & &1) == 1

      assert observation == %{
               "order_id" => "Z9999",
               "recommended_action" => "Ask the customer to confirm the order id.",
               "status" => "not_found",
               "summary" => "No order matched that id."
             }

      assert [operation_result] = result.agent_state.operation_results
      assert operation_result.output == observation

      assert result.content ==
               "Order Z9999 was not found. Ask the customer to confirm the order id."

      refute result.content =~ "with ."
      refute result.content =~ "ETA: ."
    end
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    Enum.count(results, fn {_id, result} -> result.kind == kind end)
  end

  defp event_index(events, event, filters \\ []) do
    events
    |> Jidoka.Trace.timeline()
    |> Enum.find_index(fn item ->
      item.event == event and
        Enum.all?(filters, fn {path, expected} -> get_in(item, List.wrap(path)) == expected end)
    end)
  end

  defp assert_ordered(indexes) do
    refute nil in indexes
    assert indexes == Enum.sort(indexes)
    assert length(indexes) == length(Enum.uniq(indexes))
  end

  defp expected_order do
    %{
      "carrier" => "UPS",
      "eta" => "the next business day",
      "order_id" => "A1001",
      "recommended_action" =>
        "Tell the customer the package is on schedule and ask them to watch for delivery updates.",
      "status" => "in_transit",
      "summary" => "The order left the Chicago regional hub this morning."
    }
  end

  defp journal_intents(result, kind) do
    result.journal.intents
    |> Map.values()
    |> Enum.filter(&(&1.kind == kind))
  end
end
