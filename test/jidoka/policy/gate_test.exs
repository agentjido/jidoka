defmodule Jidoka.Policy.GateTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Policy.Decision
  alias Jidoka.Policy.Gate
  alias Jidoka.Policy.Request
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.EffectInterpreter
  alias Jidoka.Turn

  test "allows one protected operation before one capability call" do
    parent = self()
    intent = operation_intent(%{city: "Paris"})

    policy = fn request, %Context{} ->
      send(parent, {:policy, request})
      {:ok, Decision.new!(outcome: :allow, rule_id: "host.operations.weather")}
    end

    operations = fn received, journal, _context ->
      assert %Decision{outcome: :allow} = Effect.Journal.policy_decision_for(journal, received)
      send(parent, {:operation, received.id})
      {:ok, %{condition: "sunny"}}
    end

    capabilities =
      Capabilities.new!(
        llm: missing_llm(),
        operations: operations,
        policy: policy
      )

    assert {:ok, %Effect.Result{status: :ok}, state} =
             EffectInterpreter.interpret_pending(state(intent), capabilities, clock: fn -> 10 end)

    assert %Decision{rule_id: "host.operations.weather", decided_at_ms: 10} =
             Effect.Journal.policy_decision_for(state.journal, intent)

    assert_receive {:policy, %Request{intent_id: intent_id}}
    assert_receive {:operation, ^intent_id}

    assert Enum.map(state.events, & &1.event) == [
             :effect_started,
             :policy_allowed,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed
           ]
  end

  test "host deny overrides untrusted advice and blocks the capability" do
    intent =
      Effect.Intent.new(:operation, %{name: "weather", arguments: %{}}, metadata: %{policy_advice: %{outcome: :allow}})

    policy = fn %Request{advice: advice}, _context ->
      assert advice == %{outcome: :allow}
      {:ok, Decision.new!(outcome: :deny, rule_id: "host.deny", reason: :not_allowed)}
    end

    capabilities =
      Capabilities.new!(
        llm: missing_llm(),
        operations: fn _, _, _ -> flunk("denied operation reached its capability") end,
        policy: policy
      )

    assert {:error, %Jidoka.Error.ExecutionError{details: details}} =
             EffectInterpreter.interpret_pending(state(intent), capabilities)

    assert inspect(details) =~ "policy_denied"
  end

  test "missing, malformed, failed, and timed-out gates fail closed" do
    %Effect.Intent{} = intent = operation_intent(%{})

    policies = [
      &Gate.missing/2,
      fn _request, _context -> {:ok, %{outcome: :allow}} end,
      fn _request, _context -> raise "policy failed" end,
      fn _request, _context -> exit(:policy_exit) end,
      fn _request, _context ->
        Process.sleep(100)
        {:ok, :late}
      end
    ]

    Enum.each(policies, fn policy ->
      capabilities =
        Capabilities.new!(
          llm: missing_llm(),
          operations: fn _, _, _ -> flunk("failed policy reached the capability") end,
          policy: policy
        )

      assert {:error, %Jidoka.Error.ExecutionError{}} =
               EffectInterpreter.interpret_pending(state(intent), capabilities, policy_timeout_ms: 2)
    end)
  end

  test "normalizes every malformed policy callback result into a typed failure" do
    intent = operation_intent(%{})

    policies = [
      {:return, fn _request, _context -> {:malformed, :tuple} end},
      {:return, fn _request, _context -> %{outcome: :allow, rule_id: "raw.map"} end},
      {:decision, fn _request, _context -> {:ok, %{outcome: :allow}} end},
      {:throw, fn _request, _context -> throw(:policy_throw) end},
      {:exit, fn _request, _context -> exit(:policy_exit) end},
      {:exception, fn _request, _context -> raise "policy exception" end}
    ]

    for {kind, policy} <- policies do
      assert {:error,
              {:policy_check_failed, :operation,
               {:invalid_policy_callback_result, ^kind, %{category: _, message: message}}}} =
               Gate.authorize(state(intent), intent, policy, [])

      assert is_binary(message)
    end
  end

  test "keeps valid allow, deny, and review callback decisions" do
    intent = operation_intent(%{})

    for outcome <- [:allow, :deny, :require_review] do
      policy = fn _request, _context ->
        {:ok, Decision.new!(outcome: outcome, rule_id: "host.#{outcome}")}
      end

      result = Gate.authorize(state(intent), intent, policy, [])

      assert elem(result, 0) == expected_gate_result(outcome)
      assert %Decision{outcome: ^outcome} = elem(result, 1)
    end
  end

  test "a review decision is reused after approval and is not called twice" do
    parent = self()
    %Effect.Intent{} = intent = operation_intent(%{})

    policy = fn _request, _context ->
      send(parent, :policy_called)
      {:ok, Decision.new!(outcome: :require_review, rule_id: "host.review")}
    end

    operations = fn _intent, _journal, _context -> {:ok, %{approved: true}} end
    capabilities = Capabilities.new!(llm: missing_llm(), operations: operations, policy: policy)

    assert {:interrupt, interrupt, interrupted_state} =
             EffectInterpreter.interpret_pending(state(intent), capabilities)

    assert_receive :policy_called

    approved = %Effect.Intent{
      intent
      | metadata: Map.put(intent.metadata, "approved_interrupt_id", interrupt.id)
    }

    resumed_state = Turn.State.set_pending_effects(interrupted_state, [approved])

    assert {:ok, %Effect.Result{status: :ok}, _state} =
             EffectInterpreter.interpret_pending(resumed_state, capabilities)

    refute_receive :policy_called
  end

  test "policy data rejects live values and default lifecycle policy fails closed" do
    assert {:error, _reason} =
             Decision.new(outcome: :allow, rule_id: "bad", evidence: %{owner: self()})

    request =
      Request.new!(
        effect_class: :execution_environment,
        action: "open",
        request_id: "request-1"
      )

    assert {:error, {:policy_denied, {:explicit_host_policy_required, :execution_environment}}} =
             Gate.check(request, &Gate.default/2)
  end

  defp state(intent) do
    spec =
      Agent.Spec.new!(
        id: "policy_gate_agent",
        instructions: "Test policy.",
        model: %{provider: :test, id: "model"}
      )

    request = Turn.Request.new!(input: "Hello", request_id: "request-1")

    Turn.State.new!(
      spec: spec,
      plan: Turn.Plan.new!(spec),
      request: request,
      agent_state: request.agent_state
    )
    |> Turn.State.set_pending_effects([intent])
  end

  defp operation_intent(arguments),
    do: Effect.Intent.new(:operation, %{name: "weather", arguments: arguments})

  defp expected_gate_result(:allow), do: :allow
  defp expected_gate_result(:deny), do: :deny
  defp expected_gate_result(:require_review), do: :review

  defp missing_llm, do: fn _intent, _journal, _context -> {:error, :missing_llm} end
end
