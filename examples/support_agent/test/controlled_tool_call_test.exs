Code.require_file("../../_support/test_helper.exs", __DIR__)
Code.require_file("../../_support/registry.exs", __DIR__)

unless Code.ensure_loaded?(JidokaExamples.TestSupport) do
  Code.require_file("../../_support/test_support.ex", __DIR__)
end

{:ok, support_agent_example} = JidokaExamples.fetch(:support_agent)
{:ok, _modules} = JidokaExamples.load(support_agent_example)

defmodule JidokaExamples.SupportAgent.ControlledToolCallTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Turn
  alias JidokaExamples.SupportAgent.Agent
  alias JidokaExamples.SupportAgent.Example
  alias JidokaExamples.TestSupport

  @moduletag proof_example: :support_agent
  @moduletag timeout: 5_000

  setup_all do
    {:ok, manifest} = JidokaExamples.fetch(:support_agent)

    assert manifest.agent == Agent

    %{manifest: manifest}
  end

  @tag proof_case: {:controlled_tool_call, :allowed_round_trip}
  test "returns a tool observation through the controlled operation path", %{manifest: manifest} do
    {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

    assert manifest.agent == Agent

    assert {:ok, %Turn.Result{} = result} =
             Example.execute(observer: self(), counter: counter)

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
    assert TestSupport.count_results(result.journal, :llm) == 2
    assert TestSupport.count_results(result.journal, :operation) == 1

    assert :ok =
             TestSupport.assert_ordered!([
               TestSupport.event_index(result.events, :control_allowed, [
                 {:operation, "lookup_order"},
                 {[:data, :control], "require_order_approval"}
               ]),
               TestSupport.event_index(result.events, :capability_call_started,
                 effect_kind: :operation,
                 operation: "lookup_order"
               ),
               TestSupport.event_index(result.events, :operation_observed, operation: "lookup_order"),
               TestSupport.event_index(result.events, :prompt_assembled, loop_index: 1),
               TestSupport.event_index(result.events, :turn_finished)
             ])
  end

  @tag proof_case: {:controlled_tool_call, :interrupted_and_approved}
  test "resumes one interrupted operation after approval", %{manifest: manifest} do
    {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

    assert manifest.agent == Agent

    assert {:hibernate, snapshot} =
             Example.execute(
               observer: self(),
               counter: counter,
               credential_ref: "credential:support-demo"
             )

    assert_receive {:order_control_called, "lookup_order", %{"order_id" => "A1001"}, true}
    assert Elixir.Agent.get(counter, & &1) == 0
    assert snapshot.turn_state.agent_state.operation_results == []
    assert TestSupport.count_results(snapshot.turn_state.journal, :operation) == 0

    assert [pending_operation] =
             Enum.filter(snapshot.turn_state.pending_effects, &(&1.kind == :operation))

    assert {:ok, [review]} = Jidoka.pending_reviews(snapshot)
    assert review.operation == "lookup_order"
    assert review.arguments == %{"order_id" => "A1001"}
    assert review.reason == :authenticated_order_access

    assert {:ok, %Turn.Result{} = result} =
             Example.approve(snapshot, review,
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
    assert TestSupport.count_results(result.journal, :operation) == 1
    assert String.starts_with?(result.content, "Order A1001 is in transit with UPS.")

    assert :ok =
             TestSupport.assert_ordered!([
               TestSupport.event_index(result.events, :control_interrupted, operation: "lookup_order"),
               TestSupport.event_index(result.events, :approval_requested, operation: "lookup_order"),
               TestSupport.event_index(result.events, :turn_hibernated),
               TestSupport.event_index(result.events, :approval_responded, operation: "lookup_order"),
               TestSupport.event_index(result.events, :approval_applied, operation: "lookup_order"),
               TestSupport.event_index(result.events, :capability_call_started,
                 effect_kind: :operation,
                 operation: "lookup_order"
               ),
               TestSupport.event_index(result.events, :operation_observed, operation: "lookup_order"),
               TestSupport.event_index(result.events, :prompt_assembled, loop_index: 1),
               TestSupport.event_index(result.events, :turn_finished)
             ])
  end

  @tag proof_case: {:controlled_tool_call, :not_found_result}
  test "preserves a not-found operation result for the next model input", %{manifest: manifest} do
    {:ok, counter} = start_supervised({Elixir.Agent, fn -> 0 end})

    assert manifest.agent == Agent

    assert {:ok, %Turn.Result{} = result} =
             Example.execute(order_id: " z9999 ", observer: self(), counter: counter)

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
