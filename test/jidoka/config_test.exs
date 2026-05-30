defmodule Jidoka.ConfigTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Generation

  test "normalizes inline model maps through ReqLLM and LLMDB" do
    assert {:ok, %LLMDB.Model{} = model} =
             Jidoka.Config.normalize_model_spec(%{provider: :test, id: "unit-model"})

    assert model.provider == :test
    assert model.id == "unit-model"
    assert Jidoka.Config.model_ref(model) == "test:unit-model"
  end

  test "returns structured errors for invalid model input" do
    assert {:error, {:model, :fast, _reason}} = Jidoka.Config.normalize_model_spec(:fast)
  end

  test "reads default generation from application config" do
    previous_default = Application.get_env(:jidoka, :default_generation)

    on_exit(fn ->
      if is_nil(previous_default) do
        Application.delete_env(:jidoka, :default_generation)
      else
        Application.put_env(:jidoka, :default_generation, previous_default)
      end
    end)

    Application.put_env(:jidoka, :default_generation, %{params: %{temperature: 0.3}})

    assert %Generation{params: %{temperature: 0.3}} = Jidoka.Config.default_generation()
  end

  test "reads runtime control defaults from application config" do
    previous_max_turns = Application.get_env(:jidoka, :default_max_model_turns)
    previous_timeout = Application.get_env(:jidoka, :default_turn_timeout_ms)

    on_exit(fn ->
      restore_env(:default_max_model_turns, previous_max_turns)
      restore_env(:default_turn_timeout_ms, previous_timeout)
    end)

    Application.put_env(:jidoka, :default_max_model_turns, "5")
    Application.put_env(:jidoka, :default_turn_timeout_ms, "2500")

    assert Jidoka.Config.default_max_model_turns() == 5
    assert Jidoka.Config.default_turn_timeout_ms() == 2_500

    spec =
      Jidoka.agent!(
        id: "configured_control_defaults_agent",
        instructions: "Use defaults.",
        model: %{provider: :test, id: "model"}
      )

    assert %{max_model_turns: 5, timeout_ms: 2_500} = Jidoka.plan!(spec)
  end

  test "model_ref accepts model input and normalized structs" do
    model = Jidoka.Config.normalize_model_spec!(%{provider: :test, id: "ref-model"})

    assert Jidoka.Config.model_ref(model) == "test:ref-model"
    assert Jidoka.Config.model_ref(%{provider: :test, id: "ref-model"}) == "test:ref-model"
  end

  defp restore_env(key, nil), do: Application.delete_env(:jidoka, key)
  defp restore_env(key, value), do: Application.put_env(:jidoka, key, value)
end
