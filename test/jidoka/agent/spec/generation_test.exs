defmodule Jidoka.Agent.Spec.GenerationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Generation

  test "normalizes flat maps as generation params" do
    assert {:ok, %Generation{} = generation} =
             Generation.from_input(%{"temperature" => 0.2, "max_tokens" => 128})

    assert generation.params == %{temperature: 0.2, max_tokens: 128}
    assert Keyword.get(Generation.to_req_llm_opts(generation), :temperature) == 0.2
    assert Keyword.get(Generation.to_req_llm_opts(generation), :max_tokens) == 128
  end

  test "preserves explicit params, provider options, and extra data" do
    generation =
      Generation.new!(
        params: %{temperature: 0.1},
        provider_options: %{openai: %{reasoning_effort: "low"}},
        extra: %{owner: "test"}
      )

    opts = Generation.to_req_llm_opts(generation)

    assert Keyword.get(opts, :temperature) == 0.1
    assert Keyword.get(opts, :provider_options) == %{openai: %{reasoning_effort: "low"}}

    assert generation.extra == %{owner: "test"}
  end

  test "rejects unknown string params instead of creating atoms" do
    generation = Generation.new!(params: %{"not_a_known_generation_option" => true})

    assert_raise ArgumentError, ~r/provider-specific values under provider_options/, fn ->
      Generation.to_req_llm_opts(generation)
    end
  end

  test "raises with a useful label for invalid generation data" do
    assert_raise ArgumentError, ~r/invalid generation/, fn ->
      Generation.to_req_llm_opts(%{params: "not a map"})
    end
  end
end
