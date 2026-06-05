defmodule Jidoka.ParallelToolCallingIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2, timeline: 1]

  test "one model turn can execute independent operation calls in parallel" do
    test_pid = self()

    task =
      Task.async(fn ->
        Jidoka.turn(spec(["slow_a", "slow_b"]), "Run both lookups.",
          llm: batched_llm(["slow_a", "slow_b"], "Both lookups finished."),
          operations: blocking_operations(test_pid, ["slow_a", "slow_b"]),
          max_parallel_operations: 2
        )
      end)

    assert_receive {:operation_started, "slow_a", slow_a_pid}, 1_000
    assert_receive {:operation_started, "slow_b", slow_b_pid}, 1_000

    send(slow_b_pid, {:release_operation, "slow_b"})
    send(slow_a_pid, {:release_operation, "slow_a"})

    assert {:ok, %Turn.Result{content: "Both lookups finished."} = result} =
             Task.await(task, 2_000)

    assert [
             %Effect.OperationResult{operation: "slow_a", output: %{"operation" => "slow_a"}},
             %Effect.OperationResult{operation: "slow_b", output: %{"operation" => "slow_b"}}
           ] = result.agent_state.operation_results

    events = timeline(result.events)

    first_completed =
      min(
        operation_event_index(events, :capability_call_completed, "slow_a"),
        operation_event_index(events, :capability_call_completed, "slow_b")
      )

    assert operation_event_index(events, :capability_call_started, "slow_a") < first_completed
    assert operation_event_index(events, :capability_call_started, "slow_b") < first_completed
  end

  test "operation batches use the configured default parallelism" do
    test_pid = self()
    operation_names = Enum.map(1..8, &"slow_#{&1}")

    task =
      Task.async(fn ->
        Jidoka.turn(spec(operation_names), "Run all lookups.",
          llm: batched_llm(operation_names, "All lookups finished."),
          operations: blocking_operations(test_pid, operation_names)
        )
      end)

    started =
      Enum.map(operation_names, fn name ->
        assert_receive {:operation_started, ^name, pid}, 1_000
        {name, pid}
      end)

    Enum.each(started, fn {name, pid} ->
      send(pid, {:release_operation, name})
    end)

    assert {:ok, %Turn.Result{content: "All lookups finished."} = result} =
             Task.await(task, 5_000)

    assert Enum.map(result.agent_state.operation_results, & &1.operation) == operation_names
  end

  test "duplicate operation calls in one batch are both executed and observed" do
    test_pid = self()

    operations =
      LocalOperations.operations(%{
        "lookup" => fn %{"id" => id} ->
          send(test_pid, {:lookup_called, id})
          {:ok, %{"id" => id}}
        end
      })

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(spec(["lookup"]), "Look up both ids.",
               llm:
                 batched_llm(
                   [
                     {"lookup", %{"id" => "A"}},
                     {"lookup", %{"id" => "A"}}
                   ],
                   "Both duplicate lookups finished."
                 ),
               operations: operations,
               max_parallel_operations: 2
             )

    assert [
             %Effect.OperationResult{operation: "lookup", effect_id: first_effect_id},
             %Effect.OperationResult{operation: "lookup", effect_id: second_effect_id}
           ] = result.agent_state.operation_results

    assert first_effect_id != second_effect_id
    assert_receive {:lookup_called, "A"}, 1_000
    assert_receive {:lookup_called, "A"}, 1_000
  end

  test "a review interrupt in a batch hibernates before any operation executes" do
    test_pid = self()

    request =
      Turn.Request.new!(
        input: "Run safe lookup and reviewed lookup.",
        metadata: %{
          test_pid: test_pid,
          operation_control_decision: {:interrupt, :approval_required}
        }
      )

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(review_spec(), request,
               llm: batched_llm(["safe_lookup", "review_lookup"], "Reviewed batch finished."),
               operations: observed_operations(test_pid, ["safe_lookup", "review_lookup"]),
               clock: clock(1_000)
             )

    assert snapshot.cursor.phase == :review
    assert snapshot.turn_state.pending_interrupt.operation == "review_lookup"
    assert length(snapshot.turn_state.pending_effects) == 2

    refute_received {:operation_called, "safe_lookup"}
    refute_received {:operation_called, "review_lookup"}

    events = timeline(snapshot.turn_state.events)
    refute Enum.any?(events, &match?(%{event: :capability_call_started, effect_kind: :operation}, &1))
    assert Enum.any?(events, &match?(%{event: :control_interrupted, operation: "review_lookup"}, &1))

    approval =
      snapshot.turn_state.pending_interrupt
      |> Review.Response.approve(responded_at_ms: 1_001)

    assert {:ok, %Turn.Result{content: "Reviewed batch finished."}} =
             Jidoka.resume(snapshot,
               approval: approval,
               llm: batched_llm(["safe_lookup", "review_lookup"], "Reviewed batch finished."),
               operations: observed_operations(test_pid, ["safe_lookup", "review_lookup"]),
               clock: clock(1_001)
             )

    assert_receive {:operation_called, "safe_lookup"}, 1_000
    assert_receive {:operation_called, "review_lookup"}, 1_000
  end

  defp spec(operation_names) do
    Agent.Spec.new!(
      id: "parallel_tool_calling_agent",
      instructions: "Use available operations before answering.",
      model: %{provider: :test, id: "model"},
      operations: Enum.map(operation_names, &Agent.Spec.Operation.new!(name: &1)),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp review_spec do
    Agent.Spec.new!(
      id: "parallel_review_agent",
      instructions: "Use available operations before answering.",
      model: %{provider: :test, id: "model"},
      operations: [
        Agent.Spec.Operation.new!(name: "safe_lookup"),
        Agent.Spec.Operation.new!(name: "review_lookup")
      ],
      controls: %{
        operations: [
          %{
            control: Jidoka.IntegrationSupport.OperationDecisionControl,
            match: %{name: "review_lookup"}
          }
        ]
      },
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp batched_llm(operations, final_content) do
    fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :operation) do
        0 -> {:ok, %{type: :operations, operations: operation_decisions(operations)}}
        _count -> {:ok, %{type: :final, content: final_content}}
      end
    end
  end

  defp operation_decisions(operations) do
    Enum.map(operations, fn
      {name, arguments} -> %{name: name, arguments: arguments}
      name when is_binary(name) -> %{name: name, arguments: %{}}
    end)
  end

  defp blocking_operations(test_pid, operation_names) do
    handlers =
      Map.new(operation_names, fn name ->
        {name,
         fn _arguments ->
           send(test_pid, {:operation_started, name, self()})

           receive do
             {:release_operation, ^name} -> {:ok, %{"operation" => name}}
           after
             1_000 -> {:error, {:operation_not_released, name}}
           end
         end}
      end)

    LocalOperations.operations(handlers)
  end

  defp observed_operations(test_pid, operation_names) do
    handlers =
      Map.new(operation_names, fn name ->
        {name,
         fn _arguments ->
           send(test_pid, {:operation_called, name})
           {:ok, %{"operation" => name}}
         end}
      end)

    LocalOperations.operations(handlers)
  end

  defp operation_event_index(events, event, operation) do
    Enum.find_index(events, &match?(%{event: ^event, operation: ^operation}, &1))
  end

  defp clock(now_ms), do: fn -> now_ms end
end
