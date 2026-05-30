defmodule Jidoka.Runtime.EffectInterpreterTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Turn

  test "records llm intents before calling capabilities and journals successful results" do
    intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})
    state = state_with_pending_effect(intent)

    llm = fn received_intent, %Effect.Journal{} = journal ->
      assert received_intent.id == intent.id
      assert Map.has_key?(journal.intents, intent.id)
      {:ok, %{type: :final, content: "ok"}}
    end

    {:ok, capabilities} = Capabilities.new(llm: llm)

    assert {:ok, %Effect.Result{} = result, %Turn.State{} = next_state} =
             EffectInterpreter.interpret_pending(state, capabilities)

    assert result.intent_id == intent.id
    assert result.kind == :llm
    assert result.status == :ok
    assert next_state.journal.results[intent.id] == result

    assert Enum.map(Jidoka.Extensions.Trace.timeline(next_state.events), & &1.event) == [
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed
           ]
  end

  test "wraps capability errors as effect results" do
    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})
    state = state_with_pending_effect(intent)

    operations = fn _intent, _journal -> {:error, :tool_failed} end
    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok,
            %Effect.Result{
              status: :error,
              output: %Jidoka.Error.ExecutionError{details: %{cause: :tool_failed}}
            }, next_state} =
             EffectInterpreter.interpret_pending(state, capabilities)

    assert %Effect.Result{status: :error} = next_state.journal.results[intent.id]

    timeline = Jidoka.Extensions.Trace.timeline(next_state.events)

    assert Enum.map(timeline, & &1.event) == [
             :effect_started,
             :capability_call_started,
             :capability_call_failed,
             :effect_failed
           ]

    assert [
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather", error: %{category: :execution}},
             %{effect_kind: :operation, operation: "weather", error: %{category: :execution}}
           ] = timeline
  end

  test "reuses journaled results without calling capabilities again" do
    intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})
    result = Effect.Result.ok(intent, %{type: :final, content: "cached"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_result(result)

    state = state_with_pending_effect(intent, journal: journal)
    llm = fn _intent, _journal -> flunk("capability should not be called when result exists") end
    {:ok, capabilities} = Capabilities.new(llm: llm)

    assert {:ok, ^result, next_state} = EffectInterpreter.interpret_pending(state, capabilities)
    assert next_state.journal == state.journal

    assert [%{event: :effect_replayed, effect_id: effect_id, effect_kind: :llm}] =
             Jidoka.Extensions.Trace.timeline(next_state.events)

    assert effect_id == intent.id
  end

  test "returns an error when no pending effect exists" do
    {:ok, capabilities} = Capabilities.new(llm: missing_llm())

    assert {:error, %Jidoka.Error.ExecutionError{details: %{reason: :missing_pending_effect}}} =
             EffectInterpreter.interpret_pending(base_state(), capabilities)
  end

  defp state_with_pending_effect(%Effect.Intent{} = intent, opts \\ []) do
    base_state()
    |> Turn.State.set_pending_effects([intent])
    |> Map.put(:journal, Keyword.get(opts, :journal, Effect.Journal.new!()))
  end

  defp base_state do
    spec =
      Agent.Spec.new!(
        id: "effect_test_agent",
        instructions: "Test effect interpreter.",
        model: %{provider: :test, id: "model"}
      )

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

    Turn.State.new!(
      spec: spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp missing_llm, do: fn _intent, _journal -> {:error, :missing_llm} end
end
