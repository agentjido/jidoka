defmodule Jidoka.Turn.StateTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Turn

  test "rejects malformed final model decisions" do
    {state, intent} = state_with_pending_llm()

    assert {:error, {:invalid_final_content, 123}} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{type: :final, content: 123})
             )
  end

  test "rejects malformed operation model decisions" do
    {state, intent} = state_with_pending_llm()

    assert {:error, {:invalid_operation_name, 123}} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{type: "operation", name: 123, arguments: %{}})
             )

    assert {:error, {:invalid_operation_arguments, "bad"}} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{type: "operation", name: "weather", arguments: "bad"})
             )
  end

  test "rejects unknown decision types and unknown operations" do
    {state, intent} = state_with_pending_llm()

    assert {:error, {:invalid_llm_decision_type, "other"}} =
             Turn.State.apply_effect_result(state, Effect.Result.ok(intent, %{type: "other"}))

    assert {:error, {:unknown_operation, "missing"}} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{type: "operation", name: "missing", arguments: %{}})
             )
  end

  test "propagates failed effects and reports unexpected results" do
    {state, intent} = state_with_pending_llm()
    operation_intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})

    assert {:error, :llm_failed} =
             Turn.State.apply_effect_result(state, Effect.Result.error(intent, :llm_failed))

    assert {:error, {:missing_pending_effect, %Turn.State{}}} =
             Turn.State.apply_effect_result(
               Turn.State.set_pending_effects(state, []),
               Effect.Result.ok(operation_intent, %{ok: true})
             )
  end

  test "applies pending effects in FIFO order" do
    {state, llm_intent} = state_with_pending_llm()
    operation_intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})

    state = Turn.State.set_pending_effects(state, [operation_intent, llm_intent])

    assert {:ok, next_state} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(operation_intent, %{temperature: 72})
             )

    assert Turn.State.current_pending_effect(next_state) == llm_intent
    assert next_state.pending_effects == [llm_intent]
  end

  test "transition accumulates events and diagnostics before commit" do
    state = %{events: [Event.build(:turn_started, [], request_id: "req_transition")]}

    transition =
      state
      |> Turn.Transition.new!()
      |> Turn.Transition.event(:prompt_assembled, request_id: "req_transition")
      |> Turn.Transition.diagnostic({:note, "checked"})

    committed = Turn.Transition.commit(transition)

    assert Enum.map(committed.events, & &1.event) == [:turn_started, :prompt_assembled]
    assert committed.diagnostics == [{:note, "checked"}]

    assert {:ok, %Turn.Transition{state: %{}}} = Turn.Transition.new(%{})

    assert_raise ArgumentError, ~r/invalid turn transition/, fn ->
      Turn.Transition.new!(%{}, events: [:bad_event])
    end
  end

  test "rejects out-of-order effect results" do
    {state, llm_intent} = state_with_pending_llm()
    operation_intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})

    state = Turn.State.set_pending_effects(state, [llm_intent, operation_intent])

    assert {:error, {:effect_result_mismatch, ^llm_intent, %Effect.Result{intent_id: intent_id}}} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(operation_intent, %{ok: true})
             )

    assert intent_id == operation_intent.id
  end

  defp state_with_pending_llm do
    spec =
      Agent.Spec.new!(
        id: "state_test_agent",
        instructions: "Test state transitions.",
        model: %{provider: :test, id: "model"},
        operations: [Operation.new!(name: "weather")]
      )

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")
    intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})

    state =
      Turn.State.new!(
        spec: spec,
        plan: plan,
        request: request,
        agent_state: request.agent_state
      )

    {Turn.State.set_pending_effects(state, [intent]), intent}
  end
end
