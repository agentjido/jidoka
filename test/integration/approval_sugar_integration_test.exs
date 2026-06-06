defmodule Jidoka.ApprovalSugarIntegrationTest.AmountApprovalPredicate do
  @moduledoc false

  use Jidoka.ApprovalPredicate

  @impl true
  def call(%Jidoka.Context{} = ctx) do
    amount = Map.get(ctx.arguments, "amount") || Map.get(ctx.arguments, :amount) || 0

    case Jidoka.Context.fetch(ctx, :test_pid) do
      {:ok, pid} -> send(pid, {:approval_predicate_called, amount})
      :error -> :ok
    end

    amount >= 100
  end
end

defmodule Jidoka.ApprovalSugarIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.ApprovalSugarIntegrationTest.AmountApprovalPredicate
  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2, timeline: 1]

  test "operation approval policy hibernates before executing and facade approval resumes" do
    test_pid = self()

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(approval_spec(), "Look up approved.",
               llm: single_operation_llm("approved_lookup", %{"id" => "A1001"}, "Approved lookup done."),
               operations: observed_operations(test_pid, ["approved_lookup"]),
               clock: clock(1_000)
             )

    assert {:ok, [%Review.Request{} = review]} = Jidoka.pending_reviews(snapshot)
    assert review.operation == "approved_lookup"
    assert review.reason == "manual_review"
    assert review.expires_at_ms == 31_000
    assert review.metadata["control_metadata"]["source"] == "operation"
    assert review.metadata["control_metadata"]["policy"]["message"] == "Review the lookup."

    refute_received {:operation_called, "approved_lookup"}

    assert {:ok, %Turn.Result{content: "Approved lookup done."}} =
             Jidoka.approve(snapshot, review,
               llm: single_operation_llm("approved_lookup", %{"id" => "A1001"}, "Approved lookup done."),
               operations: observed_operations(test_pid, ["approved_lookup"]),
               clock: clock(1_001)
             )

    assert_receive {:operation_called, "approved_lookup"}, 1_000
  end

  test "request-level approval can pause any selected operation for one turn" do
    test_pid = self()

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(base_spec(), "Run selected lookup.",
               llm: single_operation_llm("safe_lookup", %{"id" => "A1001"}, "Safe lookup done."),
               operations: observed_operations(test_pid, ["safe_lookup"]),
               require_tool_approval: [
                 only: ["safe_lookup"],
                 reason: "request_review",
                 message: "This request is running in review mode."
               ],
               clock: clock(2_000)
             )

    assert {:ok, [%Review.Request{} = review]} = Jidoka.pending_reviews(snapshot)
    assert review.operation == "safe_lookup"
    assert review.reason == "request_review"
    assert review.metadata["control_metadata"]["source"] == "request"
    assert review.metadata["control_metadata"]["policy"]["message"] == "This request is running in review mode."

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :approval,
              details: %{reason: :approval_denied, approval_reason: :not_allowed}
            }} =
             Jidoka.deny(snapshot, review,
               reason: :not_allowed,
               llm: single_operation_llm("safe_lookup", %{"id" => "A1001"}, "Safe lookup done."),
               operations: observed_operations(test_pid, ["safe_lookup"]),
               clock: clock(2_001)
             )

    refute_received {:operation_called, "safe_lookup"}
  end

  test "approval policy satisfies unsafe_once planning without custom controls" do
    assert {:ok, %Turn.Plan{}} = Jidoka.plan(approval_spec())
  end

  test "request-level approval in a parallel batch hibernates before any operation executes" do
    test_pid = self()

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(base_spec(["safe_lookup", "review_lookup"]), "Run both lookups.",
               llm:
                 batched_llm(
                   ["safe_lookup", "review_lookup"],
                   "Both lookups done."
                 ),
               operations: observed_operations(test_pid, ["safe_lookup", "review_lookup"]),
               require_tool_approval: [except: ["safe_lookup"], reason: "batch_review"],
               clock: clock(3_000)
             )

    assert snapshot.turn_state.pending_interrupt.operation == "review_lookup"
    assert length(snapshot.turn_state.pending_effects) == 2

    refute_received {:operation_called, "safe_lookup"}
    refute_received {:operation_called, "review_lookup"}

    events = timeline(snapshot.turn_state.events)
    refute Enum.any?(events, &match?(%{event: :capability_call_started, effect_kind: :operation}, &1))
    assert Enum.any?(events, &match?(%{event: :control_interrupted, operation: "review_lookup"}, &1))
  end

  test "facade approval helpers work with durable sessions" do
    test_pid = self()

    assert {:ok, session} = Jidoka.session(approval_spec(), "approval-session")

    assert {:hibernate, session, %AgentSnapshot{}} =
             Jidoka.chat(session, "Look up approved.",
               llm: single_operation_llm("approved_lookup", %{"id" => "A1001"}, "Approved lookup done."),
               operations: observed_operations(test_pid, ["approved_lookup"]),
               clock: clock(4_000)
             )

    assert {:ok, [%Review.Request{} = review]} = Jidoka.pending_reviews(session)
    assert review.operation == "approved_lookup"
    refute_received {:operation_called, "approved_lookup"}

    assert {:ok, session, %Turn.Result{content: "Approved lookup done."}} =
             Jidoka.approve(session, review,
               reason: :approved_by_test,
               metadata: %{reviewer: "unit"},
               llm: single_operation_llm("approved_lookup", %{"id" => "A1001"}, "Approved lookup done."),
               operations: observed_operations(test_pid, ["approved_lookup"]),
               clock: clock(4_001)
             )

    assert session.status == :finished
    assert session.pending_reviews == []
    assert_receive {:operation_called, "approved_lookup"}, 1_000
  end

  test "dynamic approval predicates inspect operation args and context" do
    test_pid = self()

    assert {:ok, %Turn.Result{content: "Small refund done."}} =
             Jidoka.turn(predicate_approval_spec(), request("Small refund.", %{test_pid: test_pid}),
               llm: single_operation_llm("refund_order", %{"amount" => 25}, "Small refund done."),
               operations: observed_operations(test_pid, ["refund_order"])
             )

    assert_receive {:approval_predicate_called, 25}
    assert_receive {:operation_called, "refund_order"}

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(predicate_approval_spec(), request("Large refund.", %{test_pid: test_pid}),
               llm: single_operation_llm("refund_order", %{"amount" => 250}, "Large refund done."),
               operations: observed_operations(test_pid, ["refund_order"]),
               clock: clock(5_000)
             )

    assert_receive {:approval_predicate_called, 250}
    refute_received {:operation_called, "refund_order"}

    assert {:ok, [%Review.Request{} = review]} = Jidoka.pending_reviews(snapshot)
    assert review.reason == "large_refund_review"
  end

  defp approval_spec do
    Agent.Spec.new!(
      id: "approval_sugar_agent",
      instructions: "Use approved_lookup before answering.",
      model: %{provider: :test, id: "model"},
      operations: [
        Agent.Spec.Operation.new!(
          name: "approved_lookup",
          description: "Lookup that requires approval.",
          idempotency: :unsafe_once,
          approval: [
            reason: "manual_review",
            message: "Review the lookup.",
            ttl_ms: 30_000
          ]
        )
      ],
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp predicate_approval_spec do
    Agent.Spec.new!(
      id: "predicate_approval_agent",
      instructions: "Use refund_order before answering refund questions.",
      model: %{provider: :test, id: "model"},
      operations: [
        Agent.Spec.Operation.new!(
          name: "refund_order",
          description: "Refunds an order.",
          idempotency: :unsafe_once,
          approval: [
            when: AmountApprovalPredicate,
            reason: "large_refund_review"
          ]
        )
      ],
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp base_spec(operation_names \\ ["safe_lookup"]) do
    Agent.Spec.new!(
      id: "request_approval_agent",
      instructions: "Use operations before answering.",
      model: %{provider: :test, id: "model"},
      operations: Enum.map(operation_names, &Agent.Spec.Operation.new!(name: &1)),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp single_operation_llm(name, arguments, final_content) do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 -> {:ok, %{type: :operation, name: name, arguments: arguments}}
        _count -> {:ok, %{type: :final, content: final_content}}
      end
    end
  end

  defp batched_llm(operations, final_content) do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 ->
          {:ok,
           %{
             type: :operations,
             operations: Enum.map(operations, &%{name: &1, arguments: %{}})
           }}

        _count ->
          {:ok, %{type: :final, content: final_content}}
      end
    end
  end

  defp observed_operations(test_pid, operation_names) do
    handlers =
      Map.new(operation_names, fn name ->
        {name,
         fn _arguments, _ctx ->
           send(test_pid, {:operation_called, name})
           {:ok, %{"operation" => name}}
         end}
      end)

    LocalOperations.operations(handlers)
  end

  defp request(input, context), do: Turn.Request.new!(input: input, context: context)

  defp clock(now_ms), do: fn -> now_ms end
end
