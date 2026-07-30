Code.require_file("../registry.exs", __DIR__)

{:ok, support_example} = JidokaExamples.fetch(:support_agent)
{:ok, _modules} = JidokaExamples.load(support_example)

defmodule JidokaExamples.SupportAgentTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Turn
  alias JidokaExamples.SupportAgent.Actions.LookupOrder
  alias JidokaExamples.SupportAgent.Example
  alias JidokaExamples.SupportAgent.LLMs.MockLLM

  import Jidoka.TestSupport, only: [count_results: 2, timeline: 1]

  test "looks up an order and returns its observation to the Mock LLM" do
    assert {:ok, %Turn.Result{} = result} = Example.execute(observer: self())

    assert_receive {:order_control_called, "lookup_order", control_arguments, false}
    assert control_arguments == %{"order_id" => "A1001"}

    assert_receive {:lookup_order_called, "A1001"}
    assert_receive {:order_observation_seen, observation}

    assert observation == %{
             "carrier" => "UPS",
             "eta" => "2026-06-03",
             "order_id" => "A1001",
             "recommended_action" =>
               "Tell the customer the package is on schedule and ask them to watch for delivery updates.",
             "status" => "in_transit",
             "summary" => "The order left the Chicago regional hub this morning."
           }

    assert result.content ==
             "Order A1001 is in transit with UPS. ETA: 2026-06-03. " <>
               "Tell the customer the package is on schedule and ask them to watch for delivery updates."

    assert [%Effect.OperationResult{} = operation_result] =
             result.agent_state.operation_results

    assert operation_result.operation == "lookup_order"
    assert operation_result.arguments == %{"order_id" => "A1001"}
    assert operation_result.output == observation

    assert count_results(result.journal, :llm) == 2
    assert count_results(result.journal, :operation) == 1

    assert Enum.any?(
             timeline(result.events),
             &match?(
               %{
                 event: :control_allowed,
                 operation: "lookup_order",
                 data: %{boundary: :operation, control: "require_order_approval"}
               },
               &1
             )
           )
  end

  test "pauses authenticated order access and resumes it after approval" do
    assert {:hibernate, snapshot} =
             Example.execute(
               observer: self(),
               credential_ref: "credential:support-demo"
             )

    assert_receive {:order_control_called, "lookup_order", %{"order_id" => "A1001"}, true}
    refute_receive {:lookup_order_called, _order_id}

    assert {:ok, [review]} = Jidoka.pending_reviews(snapshot)
    assert review.operation == "lookup_order"
    assert review.arguments == %{"order_id" => "A1001"}
    assert review.reason == :authenticated_order_access

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.approve(snapshot, review,
               reason: :operator_approved,
               llm: MockLLM.new("A1001", self()),
               operations: JidoActions.operations([LookupOrder]),
               operation_context: %{example_observer: self()}
             )

    assert_receive {:lookup_order_called, "A1001"}
    assert_receive {:order_observation_seen, %{"order_id" => "A1001", "status" => "in_transit"}}

    assert String.starts_with?(result.content, "Order A1001 is in transit with UPS.")
    assert count_results(result.journal, :operation) == 1
  end
end
