defmodule Jidoka.Runtime.ReqLLMTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.ReqLLM
  alias Jidoka.Effect

  test "returns an error for unsupported effect kinds" do
    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{}})

    assert {:error, {:unsupported_effect_kind, :operation}} =
             ReqLLM.generate(intent, Effect.Journal.new!(), [])
  end

  test "validates prompt payload before calling the provider" do
    intent = Effect.Intent.new(:llm, %{model: %{provider: :test, id: "model"}})

    assert {:error, {:missing_prompt_payload, _payload}} =
             ReqLLM.generate(intent, Effect.Journal.new!(), [])
  end

  test "rejects non-map prompt payloads before calling the provider" do
    intent = Effect.Intent.new(:llm, %{model: %{provider: :test, id: "model"}, prompt: "bad"})

    assert {:error, {:invalid_prompt_payload, "bad"}} =
             ReqLLM.generate(intent, Effect.Journal.new!(), [])
  end

  test "llm/1 returns a reusable effect capability function" do
    capability = ReqLLM.llm(model: %{provider: :test, id: "model"})
    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{}})

    assert is_function(capability, 3)

    assert {:error, {:unsupported_effect_kind, :operation}} =
             capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end
end
