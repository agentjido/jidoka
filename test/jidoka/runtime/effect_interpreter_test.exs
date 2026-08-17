defmodule Jidoka.Runtime.EffectInterpreterTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Runtime.Review, as: RuntimeReview
  alias Jidoka.Turn

  defmodule BlockOperationControl do
    @moduledoc false

    use Jidoka.Control, name: "block_operation_control"

    @impl true
    def call(%Jidoka.Runtime.Controls.OperationContext{}), do: {:block, :blocked_by_control}
  end

  defmodule FirstReviewControl do
    @moduledoc false

    use Jidoka.Control, name: "first_review_control"

    @impl true
    def call(%Jidoka.Runtime.Controls.OperationContext{} = context) do
      send(Jidoka.Context.get_runtime(context.ctx, :test_pid), :first_control_called)
      {:interrupt, :first_review}
    end
  end

  defmodule SecondReviewControl do
    @moduledoc false

    use Jidoka.Control, name: "second_review_control"

    @impl true
    def call(%Jidoka.Runtime.Controls.OperationContext{} = context) do
      send(Jidoka.Context.get_runtime(context.ctx, :test_pid), :second_control_called)
      {:interrupt, :second_review}
    end
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
             :policy_allowed,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed
           ]
  end

  test "turns recoverable capability errors into model-visible effect results" do
    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})
    state = state_with_pending_effect(intent)

    operations = fn _intent, _journal, _ctx ->
      {:error, Jidoka.Effect.OperationFailure.recoverable(:tool_failed)}
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok,
            %Effect.Result{
              status: :ok,
              output: %{
                "ok" => false,
                "error" => %{"kind" => "recoverable", "code" => "tool_failed"}
              }
            }, next_state} =
             EffectInterpreter.interpret_pending(state, capabilities)

    assert %Effect.Result{status: :ok, metadata: metadata} = next_state.journal.results[intent.id]
    assert metadata.operation_failure.kind == :recoverable
    assert metadata.operation_attempt_count == 1

    timeline = Jidoka.Trace.timeline(next_state.events)

    assert Enum.map(timeline, & &1.event) == [
             :effect_started,
             :policy_allowed,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed
           ]

    assert [
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather"},
             %{effect_kind: :operation, operation: "weather"}
           ] = timeline
  end

  test "retries only transport failures for retry-safe operation effects" do
    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{}})
    state = state_with_pending_effect(intent)
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    parent = self()

    operations = fn _intent, _journal, _ctx ->
      attempt = Elixir.Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(parent, {:operation_attempt, attempt})
      if attempt < 3, do: {:error, :timeout}, else: {:ok, %{value: "ready"}}
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:ok, %Effect.Result{status: :ok, output: %{value: "ready"}, metadata: metadata}, _state} =
             EffectInterpreter.interpret_pending(state, capabilities,
               operation_retry: [max_attempts: 3, backoff_ms: 1],
               operation_retry_sleep: fn delay -> send(parent, {:retry_sleep, delay}) end
             )

    assert metadata.operation_attempt_count == 3
    assert Enum.map(metadata.operation_attempts, & &1.status) == [:error, :error, :ok]
    assert_receive {:operation_attempt, 1}
    assert_receive {:retry_sleep, 1}
    assert_receive {:operation_attempt, 2}
    assert_receive {:retry_sleep, 1}
    assert_receive {:operation_attempt, 3}
  end

  test "does not retry transport failures for reconcile or unsafe operations" do
    for idempotency <- [:reconcile, :unsafe_once] do
      intent =
        Effect.Intent.new(:operation, %{name: "write", arguments: %{}}, idempotency: idempotency)

      state = state_with_pending_effect(intent)
      parent = self()

      operations = fn _intent, _journal, _ctx ->
        send(parent, {:called, idempotency})
        {:error, Jidoka.Effect.OperationFailure.transport(:timeout)}
      end

      {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

      assert {:ok, %Effect.Result{status: :error, metadata: metadata}, _state} =
               EffectInterpreter.interpret_pending(state, capabilities, operation_retry: [max_attempts: 3])

      assert metadata.operation_failure.kind == :transport
      assert metadata.operation_attempt_count == 1
      assert_receive {:called, ^idempotency}
      refute_receive {:called, ^idempotency}
    end
  end

  test "does not retry policy, review, reconciliation, cancellation, or runtime failures" do
    failures = [
      Jidoka.Effect.OperationFailure.policy(:blocked),
      Jidoka.Effect.OperationFailure.review(:approval_required),
      Jidoka.Effect.OperationFailure.reconciliation(:unknown_commit),
      Jidoka.Effect.OperationFailure.cancelled(),
      Jidoka.Effect.OperationFailure.runtime(:adapter_failed)
    ]

    for failure <- failures do
      failure_kind = failure.kind
      intent = Effect.Intent.new(:operation, %{name: "terminal_tool", arguments: %{}})
      state = state_with_pending_effect(intent)
      parent = self()

      operations = fn _intent, _journal, _ctx ->
        send(parent, {:terminal_call, failure.kind})
        {:error, failure}
      end

      {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

      assert {:ok, %Effect.Result{status: :error, metadata: metadata}, _state} =
               EffectInterpreter.interpret_pending(state, capabilities, operation_retry: [max_attempts: 3])

      assert metadata.operation_failure.kind == failure.kind
      assert metadata.operation_attempt_count == 1
      assert_receive {:terminal_call, ^failure_kind}
      refute_receive {:terminal_call, ^failure_kind}
    end
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
            }} =
             EffectInterpreter.interpret_pending(state, capabilities, operation_retry: [max_attempts: 3])
  end

  test "an approval advances only its exact control and does not bypass the host gate" do
    parent = self()
    intent = Effect.Intent.new(:operation, %{name: "reviewed_tool", arguments: %{}})

    review_controls = [
      %{control: FirstReviewControl, match: %{name: "reviewed_tool"}},
      %{control: SecondReviewControl, match: %{name: "reviewed_tool"}}
    ]

    state = state_with_pending_effect(intent, spec: spec(controls: %{operations: review_controls}))

    policy = fn _request, _context ->
      {:ok, Jidoka.Policy.Decision.new!(outcome: :require_review, rule_id: "host.review")}
    end

    operations = fn _intent, _journal, _context ->
      send(parent, :operation_called)
      {:ok, %{done: true}}
    end

    capabilities = Capabilities.new!(llm: missing_llm(), operations: operations, policy: policy)
    opts = [operation_context: %{test_pid: parent}]

    assert {:interrupt, first_interrupt, first_state} =
             EffectInterpreter.interpret_pending(state, capabilities, opts)

    assert first_interrupt.control == FirstReviewControl
    assert_receive :first_control_called

    assert {:ok, first_resumed} = approve(first_state, first_interrupt)

    assert {:interrupt, second_interrupt, second_state} =
             EffectInterpreter.interpret_pending(first_resumed, capabilities, opts)

    assert second_interrupt.control == SecondReviewControl
    refute_receive :first_control_called
    assert_receive :second_control_called

    assert {:ok, second_resumed} = approve(second_state, second_interrupt)

    assert {:interrupt, host_interrupt, host_state} =
             EffectInterpreter.interpret_pending(second_resumed, capabilities, opts)

    assert host_interrupt.control == Jidoka.Policy.Gate
    refute_receive :first_control_called
    refute_receive :second_control_called
    refute_receive :operation_called

    assert {:ok, host_resumed} = approve(host_state, host_interrupt)

    assert {:ok, %Effect.Result{status: :ok}, _state} =
             EffectInterpreter.interpret_pending(host_resumed, capabilities, opts)

    assert_receive :operation_called
    refute_receive :first_control_called
    refute_receive :second_control_called
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
            }} =
             EffectInterpreter.interpret_pending(state, capabilities, operation_retry: [max_attempts: 3])

    assert idempotency_key == intent.idempotency_key
  end

  test "incomplete reconcile and dedupe intents require application reconciliation" do
    for idempotency <- [:reconcile, :dedupe] do
      intent =
        Effect.Intent.new(:operation, %{name: "charge", arguments: %{invoice_id: "inv_1"}}, idempotency: idempotency)

      journal = Effect.Journal.new!() |> Effect.Journal.put_intent(intent)
      state = state_with_pending_effect(intent, journal: journal)

      operations = fn _intent, _journal, _ctx ->
        flunk("an incomplete #{idempotency} operation must not run automatically")
      end

      {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

      assert {:error,
              %Jidoka.Error.ExecutionError{
                phase: :effect,
                details: %{
                  reason: :effect_reconciliation_required,
                  idempotency: ^idempotency,
                  operation_name: "charge"
                }
              }} =
               EffectInterpreter.interpret_pending(state, capabilities, operation_retry: [max_attempts: 3])
    end
  end

  test "returns an error when no pending effect exists" do
    {:ok, capabilities} = Capabilities.new(llm: missing_llm())

    assert {:error, %Jidoka.Error.ExecutionError{details: %{reason: :missing_pending_effect}}} =
             EffectInterpreter.interpret_pending(base_state(), capabilities)
  end

  test "a recovery budget stops replay before an idempotent call starts" do
    parent = self()
    intent = Effect.Intent.new(:operation, %{name: "recover", arguments: %{}})
    journal = Effect.Journal.new!() |> Effect.Journal.put_intent(intent)
    plan = Turn.Plan.new!(spec())

    limits =
      Jidoka.Runtime.Limits.Applied.new!(
        max_model_turns: plan.max_model_turns,
        turn_timeout_ms: plan.timeout_ms,
        max_recovery_steps: 0
      )

    state = state_with_pending_effect(intent, journal: journal) |> Map.put(:limits, limits)

    operations = fn _intent, _journal, _context ->
      send(parent, :operation_started)
      {:ok, %{done: true}}
    end

    {:ok, capabilities} = Capabilities.new(llm: missing_llm(), operations: operations)

    assert {:error,
            {:runtime_limit_exceeded, %Jidoka.Runtime.Limits.Exceeded{kind: :recovery_steps, limit: 0, observed: 1}}} =
             EffectInterpreter.interpret_pending(state, capabilities)

    refute_receive :operation_started
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

  defp approve(state, interrupt) do
    response = Jidoka.Review.Response.new!(interrupt_id: interrupt.id, decision: :approved)
    RuntimeReview.apply_response(state, interrupt, response)
  end
end
