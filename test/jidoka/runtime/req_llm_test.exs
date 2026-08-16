defmodule Jidoka.Adapter.ReqLLMTest do
  use ExUnit.Case, async: true

  @supported_req_llm "~> 1.20.0"

  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Adapter.ReqLLM.ResponseAdapter
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias Jidoka.Effect

  test "uses the supported ReqLLM adapter line" do
    requirement =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.find_value(fn
        {:req_llm, requirement} -> requirement
        {:req_llm, requirement, _opts} -> requirement
        _dependency -> nil
      end)

    resolved_version = :req_llm |> Application.spec(:vsn) |> to_string()

    assert requirement == @supported_req_llm
    assert Version.match?(resolved_version, @supported_req_llm)
  end

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

  test "projects assembled operation contracts into ReqLLM tools" do
    prompt = %{
      operations: [
        %{
          name: "coding.read",
          description: "Read a file.",
          idempotency: :pure,
          strict: true,
          provider_options: %{openai: %{defer_loading: true}},
          parameters_schema: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"],
            "additionalProperties" => false
          }
        }
      ]
    }

    assert {:ok, [%Elixir.ReqLLM.Tool{} = tool]} = ReqLLM.tools(%{prompt: prompt})
    assert Elixir.ReqLLM.Tool.valid_name?(tool.name)
    assert tool.name == ToolProjection.provider_name("coding.read")
    assert tool.description == "Read a file."
    assert tool.strict
    assert tool.provider_options == %{openai: %{defer_loading: true}}
    assert tool.parameter_schema == hd(prompt.operations).parameters_schema

    assert %{"function" => %{"parameters" => parameters}} =
             Elixir.ReqLLM.Tool.to_schema(tool, :openai)

    assert parameters == hd(prompt.operations).parameters_schema
  end

  test "ignores a decoded structured object after parsing its streamed JSON text" do
    object = %{"type" => "operation", "name" => "lookup", "arguments" => %{}}

    response = %Elixir.ReqLLM.Response{
      id: "response-1",
      model: "gpt-4.1-mini",
      context: Elixir.ReqLLM.Context.new([]),
      message: Elixir.ReqLLM.Context.assistant([%{type: :object, object: object}])
    }

    assert {:ok, decision} =
             ResponseAdapter.decision(response, nil, Jason.encode!(object))

    assert decision.type == :operation
    assert [%{name: "lookup", arguments: %{}}] = decision.operations
    assert decision.parts == []
  end
end
