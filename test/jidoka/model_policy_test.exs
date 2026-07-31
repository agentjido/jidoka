defmodule Jidoka.ModelPolicyTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.ModelPolicy

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
end
