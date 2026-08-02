defmodule Jidoka.Parity.ProviderModelPolicyTest do
  use Jidoka.ParityCase, parity: :provider_model_policy

  alias Jidoka.Agent.Spec
  alias Jidoka.Config
  alias Jidoka.Effect

  @tag :a05
  test "one provider-neutral plan runs against different injected model capabilities" do
    spec = spec()

    for {model, answer} <- [
          {%{provider: :openai, id: "primary"}, "openai answer"},
          {%{provider: :anthropic, id: "alternate"}, "anthropic answer"}
        ] do
      llm = fn intent, _journal, _context ->
        assert Config.model_ref(intent.payload.model) == Config.model_ref(model)
        {:ok, %{type: :final, content: answer}}
      end

      assert {:ok, result} =
               Jidoka.turn(spec, "Run the provider-neutral plan",
                 llm: llm,
                 model_policy: [models: [model]]
               )

      assert result.content == answer
      assert [effect] = llm_results(result)
      assert effect.metadata.model == Config.model_ref(model)
      assert effect.metadata.provider == model.provider
    end
  end

  @tag :a06
  test "routing retries a transient model then falls back without repeating an operation" do
    test_pid = self()

    llm = fn intent, journal, _context ->
      model = Config.model_ref(intent.payload.model)
      send(test_pid, {:model_called, model})

      case model do
        "openai:primary" ->
          {:error, :timeout}

        "anthropic:fallback" ->
          if operation_result_count(journal) == 0 do
            {:ok, %{type: :operation, name: "lookup", arguments: %{"id" => "A1"}}}
          else
            {:ok, %{type: :final, content: "fallback answer"}}
          end
      end
    end

    operations = fn %Effect.Intent{payload: payload}, _journal, _context ->
      send(test_pid, {:operation_called, payload.name})
      {:ok, %{"id" => "A1", "status" => "ready"}}
    end

    policy = [
      models: [
        %{provider: :openai, id: "primary"},
        %{provider: :anthropic, id: "fallback"}
      ],
      retry: [max_attempts: 2, backoff: [type: :fixed, min: 1, max: 1]],
      sleep: fn delay -> send(test_pid, {:model_backoff, delay}) end
    ]

    assert {:ok, result} =
             Jidoka.turn(spec([%{name: "lookup"}]), "Route and look up",
               llm: llm,
               operations: operations,
               model_policy: policy
             )

    assert result.content == "fallback answer"
    assert_receive {:operation_called, "lookup"}
    refute_receive {:operation_called, "lookup"}
    assert_received {:model_backoff, 1}

    assert Enum.count(result.journal.results, fn {_id, effect} -> effect.kind == :operation end) == 1

    Enum.each(llm_results(result), fn effect ->
      assert [first, second, winner] = effect.metadata.model_attempts
      assert first.model == "openai:primary"
      assert first.failure_class == :transient
      assert second.model_attempt == 2
      assert winner.model == "anthropic:fallback"
      assert winner.winner
    end)
  end

  defp spec(operations \\ []) do
    Spec.new!(
      id: "provider_model_policy_agent",
      instructions: "Use the selected model and return one answer.",
      model: %{provider: :test, id: "declared"},
      operations: operations
    )
  end

  defp llm_results(result) do
    result.journal.results
    |> Map.values()
    |> Enum.filter(&(&1.kind == :llm))
  end

  defp operation_result_count(journal) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == :operation end)
  end
end
