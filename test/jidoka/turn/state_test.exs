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

  test "legacy copied fields cannot override the plan or pending effects" do
    {state, intent} = state_with_pending_llm()

    conflicting_spec =
      Agent.Spec.new!(
        id: "conflicting_agent",
        instructions: "Ignore this copy.",
        model: %{provider: :test, id: "other-model"}
      )

    legacy_attrs =
      state
      |> Map.from_struct()
      |> Map.put(:spec, conflicting_spec)
      |> Map.put(:operation_plan, %{name: "stale", arguments: %{}})

    assert {:ok, normalized} = Turn.State.new(legacy_attrs)
    assert normalized.plan.spec.id == "state_test_agent"
    assert normalized.pending_effects == [intent]
    refute Map.has_key?(Map.from_struct(normalized), :spec)
    refute Map.has_key?(Map.from_struct(normalized), :operation_plan)
  end

  test "fresh and restored states plan the same next effect" do
    {state, _intent} = state_with_pending_llm()
    state = Turn.State.set_pending_effects(state, [])
    snapshot = Jidoka.Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert {:ok, restored} = Turn.State.from_snapshot(snapshot)

    fresh_next =
      state
      |> Turn.Prepared.prepare_state!()
      |> Jidoka.Runtime.Spine.Steps.plan_model_effect()

    restored_next =
      restored
      |> Turn.Prepared.prepare_state!()
      |> Jidoka.Runtime.Spine.Steps.plan_model_effect()

    assert fresh_next.pending_effects == restored_next.pending_effects
    assert fresh_next.prompt == restored_next.prompt
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

  test "plans multiple operation effects from one model decision" do
    {state, intent} = state_with_pending_llm(operations: ["weather", "calendar"])

    assert {:ok, next_state} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{
                 type: "operations",
                 operations: [
                   %{name: "weather", arguments: %{"city" => "Paris"}},
                   %{name: "calendar", arguments: %{"day" => "today"}}
                 ]
               })
             )

    assert [
             %Effect.Intent{kind: :operation, payload: %{name: "weather", arguments: %{"city" => "Paris"}}},
             %Effect.Intent{kind: :operation, payload: %{name: "calendar", arguments: %{"day" => "today"}}}
           ] = next_state.pending_effects

    assert [first, second] = next_state.pending_effects
    assert first.id != second.id
    assert first.idempotency_key != second.idempotency_key
    assert first.metadata == %{batch_index: 0, batch_size: 2}
    assert second.metadata == %{batch_index: 1, batch_size: 2}
  end

  test "keeps duplicate operation calls distinct inside a batch" do
    {state, intent} = state_with_pending_llm(operations: ["weather"])

    assert {:ok, next_state} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{
                 type: "operations",
                 operations: [
                   %{name: "weather", arguments: %{"city" => "Paris"}},
                   %{name: "weather", arguments: %{"city" => "Paris"}}
                 ]
               })
             )

    assert [first, second] = next_state.pending_effects
    assert first.id != second.id
    assert first.idempotency_key != second.idempotency_key
  end

  test "stores one assistant call group and matched tool results in call order" do
    {state, intent} = state_with_pending_llm(operations: ["weather", "calendar"])

    assert {:ok, planned} =
             Turn.State.apply_effect_result(
               state,
               Effect.Result.ok(intent, %{
                 type: :operations,
                 operations: [
                   %{
                     name: "weather",
                     arguments: %{"city" => "Paris"},
                     provider_call_id: "provider_weather"
                   },
                   %{
                     name: "calendar",
                     arguments: %{"day" => "today"},
                     provider_call_id: "provider_calendar"
                   }
                 ]
               })
             )

    assert [%Agent.Message{role: :assistant, interaction: interaction}] =
             planned.agent_state.messages

    assert [weather_call, calendar_call] = hd(interaction.tool_call_groups).calls
    assert [weather_effect, calendar_effect] = planned.pending_effects
    assert weather_effect.payload.tool_call == weather_call
    assert calendar_effect.payload.tool_call == calendar_call

    assert {:ok, observed_weather} =
             Turn.State.apply_effect_result(
               planned,
               Effect.Result.ok(weather_effect, %{"temperature" => 72})
             )

    assert {:ok, observed_calendar} =
             Turn.State.apply_effect_result(
               observed_weather,
               Effect.Result.ok(calendar_effect, %{"events" => []})
             )

    assert [assistant_message, weather_message, calendar_message] =
             observed_calendar.agent_state.messages

    assert assistant_message.interaction == interaction
    assert weather_message.tool_call == weather_call
    assert calendar_message.tool_call == calendar_call

    replayed =
      observed_calendar.agent_state
      |> Agent.Transcript.append(assistant_message)
      |> Agent.Transcript.append(weather_message)

    assert replayed.messages == observed_calendar.agent_state.messages
    assert Agent.Transcript.valid?(replayed)
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

  defp state_with_pending_llm(opts \\ []) do
    operations =
      opts
      |> Keyword.get(:operations, ["weather"])
      |> Enum.map(&Operation.new!(name: &1))

    spec =
      Agent.Spec.new!(
        id: "state_test_agent",
        instructions: "Test state transitions.",
        model: %{provider: :test, id: "model"},
        operations: operations
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
