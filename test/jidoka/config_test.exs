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

  test "model_ref accepts model input and normalized structs" do
    model = Jidoka.Config.normalize_model_spec!(%{provider: :test, id: "ref-model"})

    assert Jidoka.Config.model_ref(model) == "test:ref-model"
    assert Jidoka.Config.model_ref(%{provider: :test, id: "ref-model"}) == "test:ref-model"
  end
end
