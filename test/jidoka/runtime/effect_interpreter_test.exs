defmodule Jidoka.Runtime.EffectInterpreterTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Turn

  defmodule BlockOperationControl do
    @moduledoc false

    use Jidoka.Control, name: "block_operation_control"

    @impl true
    def call(%Jidoka.Runtime.Controls.OperationContext{}), do: {:block, :blocked_by_control}
  end

  test "records llm intents before calling capabilities and journals successful results" do
    intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})
    state = state_with_pending_effect(intent)

    llm = fn received_intent, %Effect.Journal{} = journal, ctx ->
      assert received_intent.id == intent.id
      assert Map.has_key?(journal.intents, intent.id)
      assert Jidoka.Context.get_runtime(ctx, :llm_only) == true
      assert Jidoka.Context.get_runtime(ctx, :operation_only) == nil
      {:ok, %{type: :final, content: "ok"}}
    end

    {:ok, capabilities} = Capabilities.new(llm: llm)

    assert {:ok, %Effect.Result{} = result, %Turn.State{} = next_state} =
             EffectInterpreter.interpret_pending(state, capabilities,
               llm_context: %{llm_only: true},
               operation_context: %{operation_only: true}
             )

    assert result.intent_id == intent.id
    assert result.kind == :llm
    assert result.status == :ok
    assert next_state.journal.results[intent.id] == result

    assert Enum.map(Jidoka.Trace.timeline(next_state.events), & &1.event) == [
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed
           ]
  end

  test "wraps capability errors as effect results" do
    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})
    state = state_with_pending_effect(intent)

    operations = fn _intent, _journal, _ctx -> {:error, :tool_failed} end
    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok,
            %Effect.Result{
              status: :error,
              output: %Jidoka.Error.ExecutionError{details: %{cause: :tool_failed}}
            }, next_state} =
             EffectInterpreter.interpret_pending(state, capabilities)

    assert %Effect.Result{status: :error} = next_state.journal.results[intent.id]

    timeline = Jidoka.Trace.timeline(next_state.events)

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

  test "times out and cancels hung capabilities" do
    parent = self()
    intent = Effect.Intent.new(:operation, %{name: "hung_tool", arguments: %{}})
    state = state_with_pending_effect(intent)

    operations = fn _intent, _journal, _ctx ->
      send(parent, {:capability_started, self()})
      Process.sleep(5_000)
      {:ok, %{late: true}}
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok,
            %Effect.Result{
              status: :error,
              output: %Jidoka.Error.ExecutionError{
                details: %{
                  reason: :capability_timeout,
                  effect_kind: :operation,
                  timeout_ms: 5
                }
              }
            }, next_state} =
             EffectInterpreter.interpret_pending(state, capabilities, capability_timeout_ms: 5)

    assert_receive {:capability_started, capability_pid}
    refute Process.alive?(capability_pid)
    assert %Effect.Result{status: :error} = next_state.journal.results[intent.id]
  end

  test "capability process exits are isolated from the interpreter" do
    intent = Effect.Intent.new(:operation, %{name: "crashing_tool", arguments: %{}})
    state = state_with_pending_effect(intent)

    operations = fn _intent, _journal, _ctx ->
      Process.exit(self(), :kill)
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok,
            %Effect.Result{
              status: :error,
              output: %Jidoka.Error.ExecutionError{
                details: %{
                  reason: :capability_exit,
                  exit_reason: :killed
                }
              }
            }, next_state} =
             EffectInterpreter.interpret_pending(state, capabilities, capability_timeout_ms: 50)

    assert %Effect.Result{status: :error} = next_state.journal.results[intent.id]
  end

  test "untrusted intent metadata cannot bypass operation controls" do
    intent =
      Effect.Intent.new(
        :operation,
        %{name: "dangerous_tool", arguments: %{}},
        metadata: %{operation_controls_allowed: true}
      )

    state =
      state_with_pending_effect(intent,
        spec:
          spec(
            controls: %{
              operation: %{
                control: BlockOperationControl,
                match: %{name: "dangerous_tool"}
              }
            }
          )
      )

    operations = fn _intent, _journal, _ctx ->
      flunk("operation capability must not be called when a control blocks")
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{reason: :control_blocked, boundary: :operation}
            }} = EffectInterpreter.interpret_pending(state, capabilities)
  end

  test "reuses journaled results without calling capabilities again" do
    intent = Effect.Intent.new(:llm, %{prompt: %{messages: []}})
    result = Effect.Result.ok(intent, %{type: :final, content: "cached"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_result(result)

    state = state_with_pending_effect(intent, journal: journal)
    llm = fn _intent, _journal, _ctx -> flunk("capability should not be called when result exists") end
    {:ok, capabilities} = Capabilities.new(llm: llm)

    assert {:ok, ^result, next_state} = EffectInterpreter.interpret_pending(state, capabilities)
    assert next_state.journal == state.journal

    assert [%{event: :effect_replayed, effect_id: effect_id, effect_kind: :llm}] =
             Jidoka.Trace.timeline(next_state.events)

    assert effect_id == intent.id
  end

  test "reuses journaled operation results without calling operations again" do
    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{city: "Paris"}})
    result = Effect.Result.ok(intent, %{"city" => "Paris", "condition" => "sunny"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)
      |> Effect.Journal.put_result(result)

    state = state_with_pending_effect(intent, journal: journal)

    operations = fn _intent, _journal, _ctx ->
      flunk("operation should not be called when result exists")
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok, ^result, next_state} = EffectInterpreter.interpret_pending(state, capabilities)
    assert next_state.journal == state.journal

    assert [%{event: :effect_replayed, effect_id: effect_id, effect_kind: :operation}] =
             Jidoka.Trace.timeline(next_state.events)

    assert effect_id == intent.id
  end

  test "incomplete unsafe operation intents are not retried automatically" do
    intent =
      Effect.Intent.new(:operation, %{name: "refund", arguments: %{order_id: "ord_1"}}, idempotency: :unsafe_once)

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)

    state = state_with_pending_effect(intent, journal: journal)

    operations = fn _intent, _journal, _ctx ->
      flunk("unsafe operation should not be retried when its prior intent is incomplete")
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :effect,
              details: %{
                reason: :unsafe_once_incomplete_effect,
                operation_name: "refund",
                idempotency: :unsafe_once,
                idempotency_key: idempotency_key
              }
            }} = EffectInterpreter.interpret_pending(state, capabilities)

    assert idempotency_key == intent.idempotency_key
  end

  test "returns an error when no pending effect exists" do
    {:ok, capabilities} = Capabilities.new(llm: missing_llm())

    assert {:error, %Jidoka.Error.ExecutionError{details: %{reason: :missing_pending_effect}}} =
             EffectInterpreter.interpret_pending(base_state(), capabilities)
  end

  defp state_with_pending_effect(%Effect.Intent{} = intent, opts \\ []) do
    opts
    |> base_state()
    |> Turn.State.set_pending_effects([intent])
    |> Map.put(:journal, Keyword.get(opts, :journal, Effect.Journal.new!()))
  end

  defp base_state(opts \\ []) do
    spec = Keyword.get_lazy(opts, :spec, &spec/0)

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

    Turn.State.new!(
      spec: spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp spec(overrides \\ []) do
    [
      id: "effect_test_agent",
      instructions: "Test effect interpreter.",
      model: %{provider: :test, id: "model"}
    ]
    |> Keyword.merge(overrides)
    |> Agent.Spec.new!()
  end

  defp missing_llm, do: fn _intent, _journal, _ctx -> {:error, :missing_llm} end
end
