defmodule Jidoka.ModelPolicyTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.ModelPolicy
  alias Jidoka.Runtime.Capabilities

  defmodule ModuleCallbacks do
    @moduledoc false

    def select(models, _context), do: {:ok, Enum.reverse(models)}
    def classify(:retry), do: :transient
    def classify(_reason), do: :permanent
  end

  defmodule InvalidClassifier do
    @moduledoc false

    def classify(_reason), do: :unknown
  end

  @primary %{provider: :openai, id: "primary"}
  @fallback %{provider: :anthropic, id: "fallback"}

  defp spec(operations \\ []) do
    Spec.new!(
      id: "model_policy",
      instructions: "Use the available operation.",
      model: %{provider: :test, id: "static"},
      operations: operations
    )
  end

  test "selects a model for each call from trusted LLM context" do
    test_pid = self()

    select = fn models, context ->
      send(test_pid, {:selector_context, context.runtime, context.loop_index})

      if Jidoka.Context.get_runtime(context, :preferred) == :fallback do
        Enum.reverse(models)
      else
        models
      end
    end

    llm = fn intent, _journal, _context ->
      model = Config.model_ref(intent.payload.model)
      send(test_pid, {:selected_model, model, intent.payload.prompt.model})
      {:ok, %{type: :final, content: "routed"}}
    end

    assert {:ok, result} =
             Jidoka.turn(spec(), "Route this",
               llm: llm,
               llm_context: %{preferred: :fallback, routing_token: "secret"},
               model_policy: [models: [@primary, @fallback], select: select]
             )

    assert_receive {:selector_context, %{preferred: :fallback, routing_token: "secret"}, 0}
    assert_receive {:selected_model, "anthropic:fallback", "anthropic:fallback"}

    [llm_result] = Enum.filter(Map.values(result.journal.results), &(&1.kind == :llm))
    assert llm_result.metadata.model == "anthropic:fallback"
    assert llm_result.metadata.provider == :anthropic

    assert llm_result.metadata.model_attempts == [
             %{
               attempt: 1,
               model_attempt: 1,
               provider: :anthropic,
               model: "anthropic:fallback",
               status: :ok,
               winner: true
             }
           ]
  end

  test "retries transient model failures, falls back, and does not repeat operations" do
    test_pid = self()

    llm = fn intent, journal, _context ->
      model = Config.model_ref(intent.payload.model)
      send(test_pid, {:model_call, model})

      case model do
        "openai:primary" ->
          {:error, :timeout}

        "anthropic:fallback" ->
          llm_results = Enum.count(journal.results, fn {_id, result} -> result.kind == :llm end)

          if llm_results == 0 do
            {:ok, %{type: :operation, name: "lookup", arguments: %{id: "A-1"}}}
          else
            {:ok, %{type: :final, content: "fallback complete"}}
          end
      end
    end

    operations = fn %Effect.Intent{payload: payload}, _journal, _context ->
      send(test_pid, {:operation_call, payload.name})
      {:ok, %{value: "found"}}
    end

    classify = fn
      :timeout -> :transient
      _reason -> :permanent
    end

    sleep = fn delay -> send(test_pid, {:model_backoff, delay}) end

    policy = [
      models: [@primary, @fallback],
      classify: classify,
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 5, max: 5]],
      sleep: sleep
    ]

    assert {:ok, result} =
             Jidoka.turn(
               spec([%{name: "lookup", idempotency: :idempotent}]),
               "Look up A-1",
               llm: llm,
               operations: operations,
               model_policy: policy
             )

    assert result.content == "fallback complete"
    assert_receive {:operation_call, "lookup"}
    refute_receive {:operation_call, "lookup"}

    assert_received {:model_backoff, 5}
    assert Enum.count(result.journal.results, fn {_id, effect} -> effect.kind == :operation end) == 1

    llm_results =
      result.journal.results
      |> Map.values()
      |> Enum.filter(&(&1.kind == :llm))

    assert length(llm_results) == 2

    Enum.each(llm_results, fn effect ->
      assert [first, second, winner] = effect.metadata.model_attempts
      assert first.model == "openai:primary"
      assert first.status == :error
      assert first.failure_class == :transient
      assert second.model_attempt == 2
      assert second.status == :error
      assert winner.model == "anthropic:fallback"
      assert winner.status == :ok
      assert winner.winner
    end)

    completed_model_events =
      Enum.filter(result.events, &(&1.event == :capability_call_completed and &1.effect_kind == :llm))

    assert length(completed_model_events) == 2
    assert Enum.all?(completed_model_events, &(length(&1.data.model_attempts) == 3))
  end

  test "does not retry permanent failures before fallback" do
    test_pid = self()

    llm = fn intent, _journal, _context ->
      case Config.model_ref(intent.payload.model) do
        "openai:primary" -> {:error, :bad_request}
        "anthropic:fallback" -> {:ok, %{type: :final, content: "ok"}}
      end
    end

    policy = [
      models: [@primary, @fallback],
      retry: [max_attempts: 3, backoff: [type: :fixed, min: 10, max: 10]],
      sleep: fn delay -> send(test_pid, {:unexpected_sleep, delay}) end
    ]

    assert {:ok, result} = Jidoka.turn(spec(), "Run", llm: llm, model_policy: policy)
    refute_receive {:unexpected_sleep, _delay}

    [effect] = Enum.filter(Map.values(result.journal.results), &(&1.kind == :llm))
    assert Enum.map(effect.metadata.model_attempts, & &1.status) == [:error, :ok]
    assert hd(effect.metadata.model_attempts).failure_class == :permanent
  end

  test "returns attempt evidence when all models fail" do
    llm = fn _intent, _journal, _context -> {:error, :timeout} end

    policy = [
      models: [@primary, @fallback],
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 0, max: 0]]
    ]

    assert {:error, error} = Jidoka.turn(spec(), "Run", llm: llm, model_policy: policy)
    assert Jidoka.Error.category(error) == :execution

    error = Jidoka.Error.to_map(error)
    assert error.phase == :model
    assert error.details.cause == :models_exhausted
    assert length(error.details.model_attempts) == 4
  end

  test "validates policy callbacks and classifies common transient failures" do
    assert {:error, {:invalid_model_policy_callback, :select, String}} =
             ModelPolicy.new(models: [@primary], select: String)

    assert {:error, {:invalid_model_policy, [:bad]}} = ModelPolicy.new([:bad])
    assert {:error, config_error} = Jidoka.turn(spec(), "Run", model_policy: [select: String])
    assert Jidoka.Error.category(config_error) == :configuration

    assert ModelPolicy.classify(:timeout) == :transient
    assert ModelPolicy.classify({:error, :timeout}) == :transient
    assert ModelPolicy.classify(%{status: nil, reason: :timeout}) == :transient
    assert ModelPolicy.classify(%{status: 429}) == :transient
    assert ModelPolicy.classify(%{status: 503}) == :transient
    assert ModelPolicy.classify(:bad_request) == :permanent
  end

  test "rejects selector models outside the declared candidate set" do
    rogue = %{provider: :openai, id: "rogue"}
    llm = fn _intent, _journal, _context -> flunk("an undeclared model reached the provider") end

    assert {:error, error} =
             Jidoka.turn(spec(), "Run",
               llm: llm,
               model_policy: [
                 models: [@primary, @fallback],
                 select: fn _models, _context -> rogue end
               ]
             )

    assert %{
             phase: :model,
             details: %{
               cause: %{
                 type: "tuple",
                 values: [
                   :undeclared_model_policy_selection,
                   "openai:rogue",
                   ["anthropic:fallback", "openai:primary"]
                 ]
               }
             }
           } = Jidoka.Error.to_map(error)
  end

  test "selector routes use the declared model data" do
    declared =
      %{provider: :openai, id: "primary", limits: %{context: 1_000, input: 800}}

    selected =
      %{provider: :openai, id: "primary", limits: %{context: 50_000, input: 40_000}}

    llm = fn intent, _journal, _context ->
      assert intent.payload.model.limits.input == 800
      {:ok, %{type: :final, content: "declared route"}}
    end

    assert {:ok, result} =
             Jidoka.turn(spec(), "Run",
               llm: llm,
               model_policy: [
                 models: [declared],
                 select: fn _models, _context -> selected end
               ]
             )

    assert result.content == "declared route"
  end

  test "validates direct policy constructors and model declarations" do
    {:ok, base_model} = Config.normalize_model_spec(@primary)
    empty = ModelPolicy.new!(models: [])

    assert {:ok, ^empty} = ModelPolicy.normalize(empty)
    assert {:ok, [^base_model]} = ModelPolicy.declared_models(empty, base_model)
    assert {:ok, [^base_model]} = ModelPolicy.declared_models(nil, base_model)

    assert {:error, {:invalid_model_policy, :invalid}} = ModelPolicy.new(:invalid)
    assert {:error, {:invalid_model_policy_models, :invalid}} = ModelPolicy.new(models: :invalid)

    assert {:error, {:invalid_model_policy_callback, :select, "invalid"}} =
             ModelPolicy.new(models: [@primary], select: "invalid")

    assert {:error, {:invalid_model_policy_sleep, :invalid}} =
             ModelPolicy.new(models: [@primary], sleep: :invalid)

    assert {:error, {:invalid_model_policy_retry, _reason}} =
             ModelPolicy.new(models: [@primary], retry: :invalid)

    assert_raise ArgumentError, ~r/invalid model policy/, fn ->
      ModelPolicy.new!(models: :invalid)
    end
  end

  test "classifies all built-in transient error shapes" do
    assert ModelPolicy.classify(struct(Req.TransportError, reason: :closed)) == :transient
    assert ModelPolicy.classify({:capability_timeout, :llm, 10}) == :transient
    assert ModelPolicy.classify({:econnrefused, %{host: "localhost"}}) == :transient
  end

  test "wraps module callbacks and keeps the winning decision metadata" do
    llm = fn intent, _journal, _context ->
      {:ok, Effect.LLMDecision.final(Config.model_ref(intent.payload.model))}
    end

    capabilities = Capabilities.new!(llm: llm)

    policy =
      ModelPolicy.new!(
        models: [@primary, @fallback],
        select: ModuleCallbacks,
        classify: ModuleCallbacks
      )

    assert {:ok, wrapped} = ModelPolicy.wrap(capabilities, policy)

    intent = Effect.Intent.new(:llm, %{prompt: %{}})

    assert {:ok, %Effect.LLMDecision{content: "anthropic:fallback", metadata: metadata}} =
             wrapped.llm.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))

    assert metadata.provider == :anthropic
    assert [%{winner: true}] = metadata.model_attempts

    assert {:ok, ^capabilities} = ModelPolicy.wrap(capabilities, nil)
  end

  test "normalizes provider failures and unusual successful capability values" do
    context = Jidoka.Context.from_data!(%{})
    intent = Effect.Intent.new(:llm, %{prompt: %{}})
    journal = Effect.Journal.new!()

    cases = [
      {fn _intent, _journal, _context -> :invalid end, :invalid_capability_result},
      {fn _intent, _journal, _context -> raise "provider failed" end, RuntimeError},
      {fn _intent, _journal, _context -> throw(:provider_failed) end, :throw}
    ]

    Enum.each(cases, fn {llm, expected_failure} ->
      capabilities = Capabilities.new!(llm: llm)
      assert {:ok, wrapped} = ModelPolicy.wrap(capabilities, models: [@primary])

      assert {:error, {:model_policy_failed, [attempt], :models_exhausted}} =
               wrapped.llm.(intent, journal, context)

      assert inspect(attempt.failure) =~ inspect(expected_failure)
    end)

    for output <- [%{"metadata" => "invalid", value: 1}, :raw_value] do
      capabilities = Capabilities.new!(llm: fn _intent, _journal, _context -> {:ok, output} end)
      assert {:ok, wrapped} = ModelPolicy.wrap(capabilities, models: [@primary])
      assert {:ok, result} = wrapped.llm.(intent, journal, context)

      if is_map(output) do
        assert result.metadata.provider == :openai
      else
        assert result == output
      end
    end
  end

  test "reports selector, classifier, and backoff failures" do
    capability = fn _intent, _journal, _context -> {:error, :retry} end
    capabilities = Capabilities.new!(llm: capability)
    context = Jidoka.Context.from_data!(%{})
    intent = Effect.Intent.new(:llm, %{prompt: %{}})
    journal = Effect.Journal.new!()

    assert {:ok, wrapped} =
             ModelPolicy.wrap(capabilities,
               models: [@primary],
               select: fn _models, _context -> raise "selector failed" end
             )

    assert {:error, {:model_policy_failed, [], {:model_selector_failed, %RuntimeError{}}}} =
             wrapped.llm.(intent, journal, context)

    assert {:ok, wrapped} =
             ModelPolicy.wrap(capabilities,
               models: [@primary],
               classify: InvalidClassifier
             )

    assert {:error, {:model_policy_failed, [_attempt], {:invalid_model_failure_class, :unknown}}} =
             wrapped.llm.(intent, journal, context)

    assert {:ok, wrapped} =
             ModelPolicy.wrap(capabilities,
               models: [@primary],
               classify: ModuleCallbacks,
               retry: [max_attempts: 2, backoff: [type: :exponential, min: 2, max: 2]],
               sleep: fn _delay -> {:error, :sleep_failed} end
             )

    assert {:error, {:model_policy_failed, [_attempt], {:model_backoff_failed, :sleep_failed}}} =
             wrapped.llm.(intent, journal, context)
  end

  test "requires a model when a wrapped empty policy receives no routed model" do
    capabilities =
      Capabilities.new!(llm: fn _intent, _journal, _context -> {:ok, :unexpected} end)

    assert {:ok, wrapped} = ModelPolicy.wrap(capabilities, models: [])
    intent = Effect.Intent.new(:llm, %{prompt: %{}})

    assert {:error, {:model_policy_failed, [], :missing_model_policy_models}} =
             wrapped.llm.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end
end
