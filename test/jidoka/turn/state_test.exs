defmodule Jidoka.Turn.StateTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
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

    assert {:error, {:unexpected_effect_result, %Turn.State{}, %Effect.Result{}}} =
             Turn.State.apply_effect_result(
               %{state | pending_effect: nil},
               Effect.Result.ok(operation_intent, %{ok: true})
             )
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

    {%{state | pending_effect: intent}, intent}
  end
end
