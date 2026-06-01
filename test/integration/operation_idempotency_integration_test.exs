defmodule Jidoka.OperationIdempotencyIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  test "unsafe once operations fail preflight and runtime planning without a control" do
    spec =
      Agent.Spec.new!(
        id: "unsafe_policy_agent",
        instructions: "Refund orders only when allowed.",
        operations: [
          Operation.new!(
            name: "refund_order",
            description: "Starts a refund.",
            idempotency: :unsafe_once
          )
        ]
      )

    assert {:error,
            %Jidoka.Error.ConfigError{
              field: :controls,
              details: %{
                reason: :unsafe_once_requires_control,
                operation_name: "refund_order",
                idempotency: :unsafe_once
              }
            }} = Jidoka.preflight(spec, "Refund order_123")

    llm = fn _intent, _journal ->
      flunk("LLM should not be called when unsafe operation policy is invalid")
    end

    assert {:error,
            %Jidoka.Error.ConfigError{
              field: :controls,
              details: %{
                reason: :unsafe_once_requires_control,
                operation_name: "refund_order",
                idempotency: :unsafe_once
              }
            }} = Jidoka.run_turn(spec, "Refund order_123", llm: llm)
  end

  test "controlled unsafe once operations can execute through the normal turn loop" do
    test_pid = self()

    spec =
      Agent.Spec.new!(
        id: "controlled_unsafe_policy_agent",
        instructions: "Refund orders only when allowed.",
        operations: [
          Operation.new!(
            name: "refund_order",
            description: "Starts a refund.",
            idempotency: :unsafe_once
          )
        ],
        controls:
          Controls.new!(
            operations: [
              %{control: ApprovalControl, match: %{name: "refund_order"}}
            ]
          ),
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => "order_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Refund refund_123 is queued."}}
      end
    end

    operations =
      LocalOperations.operations(%{
        refund_order: fn intent, _journal ->
          arguments = Jidoka.Schema.get_key(intent.payload, :arguments)
          send(test_pid, {:refund_called, arguments, intent.idempotency})

          {:ok,
           %{
             "order_id" => arguments["order_id"],
             "refund_id" => "refund_123",
             "status" => "queued"
           }}
        end
      })

    assert {:ok, %Turn.Result{content: "Refund refund_123 is queued."} = result} =
             Jidoka.run_turn(
               spec,
               Turn.Request.new!(input: "Refund order_123", metadata: %{test_pid: test_pid}),
               llm: llm,
               operations: operations
             )

    assert [%Effect.OperationResult{operation: "refund_order"}] =
             result.agent_state.operation_results

    assert_receive {:operation_control_called, "require_approval", "refund_order", %{"order_id" => "order_123"}}

    assert_receive {:refund_called, %{"order_id" => "order_123"}, :unsafe_once}
  end

  test "operation effects replay from a journaled result without duplicate execution" do
    test_pid = self()

    spec =
      Agent.Spec.new!(
        id: "operation_replay_agent",
        instructions: "Look up weather, then answer.",
        operations: [
          Operation.new!(
            name: "weather",
            description: "Looks up weather.",
            idempotency: :idempotent
          )
        ],
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      send(test_pid, {:llm_called, count_results(journal, :llm)})

      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "weather",
             arguments: %{"city" => "Paris"}
           }}

        1 ->
          assert journal_has_operation_result?(journal, "weather")
          {:ok, %{type: :final, content: "Paris is sunny."}}
      end
    end

    operations = fn _intent, _journal ->
      flunk("operation should not be called when the journal already has its result")
    end

    assert {:hibernate, %AgentSnapshot{} = prompt_snapshot} =
             Jidoka.run_turn(spec, "Weather in Paris?",
               llm: llm,
               operations: operations,
               checkpoint: :after_each_phase
             )

    assert {:hibernate, %AgentSnapshot{} = operation_snapshot} =
             Jidoka.resume(prompt_snapshot,
               llm: llm,
               operations: operations,
               checkpoint: :after_each_phase
             )

    pending_effect = Turn.State.current_pending_effect(operation_snapshot.turn_state)
    assert pending_effect.kind == :operation

    journal =
      operation_snapshot.turn_state.journal
      |> Effect.Journal.put_intent(pending_effect)
      |> Effect.Journal.put_result(Effect.Result.ok(pending_effect, %{"city" => "Paris", "condition" => "sunny"}))

    %Turn.State{} = operation_state = operation_snapshot.turn_state

    replay_snapshot =
      %AgentSnapshot{
        operation_snapshot
        | turn_state: %Turn.State{operation_state | journal: journal}
      }

    assert {:ok, %Turn.Result{content: "Paris is sunny."} = result} =
             Jidoka.resume(replay_snapshot, llm: llm, operations: operations)

    assert [%Effect.OperationResult{operation: "weather"}] =
             result.agent_state.operation_results

    assert_receive {:llm_called, 0}
    assert_receive {:llm_called, 1}
    refute_received {:llm_called, _count}
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  defp journal_has_operation_result?(%Effect.Journal{intents: intents, results: results}, name) do
    results
    |> Enum.any?(fn
      {intent_id, %Effect.Result{kind: :operation, status: :ok}} ->
        intent = Map.fetch!(intents, intent_id)
        Jidoka.Schema.get_key(intent.payload, :name) == name

      _result ->
        false
    end)
  end
end
