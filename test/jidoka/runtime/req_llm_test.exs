defmodule Jidoka.Adapter.ReqLLMTest.FakeGeneration do
  @moduledoc false

  def generate_text(%LLMDB.Model{id: "text_error"}, _messages, opts) do
    refute_private_options(opts)
    {:error, :provider_failed}
  end

  def generate_text(%LLMDB.Model{} = model, messages, opts) do
    refute_private_options(opts)
    true = messages != []
    {:ok, response(model, ~s({"type":"final","content":"text complete"}))}
  end

  def stream_text(%LLMDB.Model{id: "stream_start_error"}, _messages, opts) do
    refute_private_options(opts)
    {:error, :stream_start_failed}
  end

  def stream_text(%LLMDB.Model{} = model, messages, opts) do
    refute_private_options(opts)
    true = messages != []
    {:ok, %{model: model, mode: model.id}}
  end

  def response(%LLMDB.Model{} = model, text) do
    %ReqLLM.Response{
      id: "response-#{model.id}",
      model: model.id,
      context: ReqLLM.Context.new([]),
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop
    }
  end

  defp refute_private_options(opts) do
    false = Keyword.has_key?(opts, :generation_module)
    false = Keyword.has_key?(opts, :stream_response_module)
    :ok
  end
end

defmodule Jidoka.Adapter.ReqLLMTest.FakeStreamResponse do
  @moduledoc false

  alias Jidoka.Adapter.ReqLLMTest.FakeGeneration

  def process_stream(%{mode: "stream_process_error"}, _opts), do: {:error, :stream_failed}

  def process_stream(%{model: model}, opts) do
    callback = Keyword.fetch!(opts, :on_chunk)
    callback.(ReqLLM.StreamChunk.thinking("check"))
    callback.(ReqLLM.StreamChunk.text(~s({"type":"final","content":"stream complete"})))
    {:ok, FakeGeneration.response(model, "")}
  end
end

defmodule Jidoka.Adapter.ReqLLMTest do
  use ExUnit.Case, async: true

  @supported_req_llm "~> 1.21.0"

  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Adapter.ReqLLM.ResponseAdapter
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias Jidoka.Adapter.ReqLLMTest.{FakeGeneration, FakeStreamResponse}
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

  test "validates prompt operation contracts and provider-safe names" do
    assert {:error, {:invalid_prompt_operations, :invalid}} =
             ReqLLM.tools(%{operations: :invalid})

    assert {:error, {:invalid_prompt_operation, 0, {:invalid_operation_contract, :invalid}}} =
             ReqLLM.tools(%{operations: [:invalid]})

    assert {:error, {:invalid_prompt_operation, 0, _reason}} =
             ReqLLM.tools(%{operations: [%{description: "missing name"}]})

    provider_name = ToolProjection.provider_name("...!!!...")
    assert provider_name =~ "jidoka_operation_"
    assert Elixir.ReqLLM.Tool.valid_name?(provider_name)
  end

  test "uses default tool descriptions and inert callbacks" do
    assert {:ok, [tool]} =
             ReqLLM.tools(%{
               operations: [
                 %{
                   name: "lookup",
                   description: "",
                   idempotency: :pure,
                   parameters_schema: %{"type" => "object"}
                 }
               ]
             })

    assert tool.description == "Run the lookup operation."
    assert {:error, :jidoka_runtime_dispatch_only} = tool.callback.(%{})
  end

  test "runs the non-streaming provider boundary through an injected generation module" do
    intent = llm_intent()

    assert {:ok, decision} =
             ReqLLM.generate(intent, Effect.Journal.new!(),
               model: %{provider: :test, id: "text_success"},
               generation_module: FakeGeneration,
               temperature: 0.25
             )

    assert decision.type == :final
    assert decision.content == "text complete"

    assert {:error, :provider_failed} =
             ReqLLM.generate(intent, Effect.Journal.new!(),
               model: %{provider: :test, id: "text_error"},
               generation_module: FakeGeneration,
               stream_to: self(),
               stream: false
             )

    assert_receive {:jidoka_turn_event, %{data: %{type: :error}}}
  end

  test "runs streaming success and failure paths through injected modules" do
    intent = llm_intent()
    callback = fn event -> send(self(), {:callback_event, event.data.type}) end

    assert {:ok, decision} =
             ReqLLM.generate(intent, Effect.Journal.new!(),
               model: %{provider: :test, id: "stream_success"},
               generation_module: FakeGeneration,
               stream_response_module: FakeStreamResponse,
               stream_to: {:pid, self()},
               on_event: callback
             )

    assert decision.content == "stream complete"
    assert_receive {:callback_event, :reasoning_delta}
    assert_receive {:callback_event, :text_delta}
    assert_receive {:callback_event, :finish}

    assert {:error, :stream_failed} =
             ReqLLM.generate(intent, Effect.Journal.new!(),
               model: %{provider: :test, id: "stream_process_error"},
               generation_module: FakeGeneration,
               stream_response_module: FakeStreamResponse,
               stream: true
             )

    assert {:error, :stream_start_failed} =
             ReqLLM.generate(intent, Effect.Journal.new!(),
               model: %{provider: :test, id: "stream_start_error"},
               generation_module: FakeGeneration,
               stream_response_module: FakeStreamResponse,
               stream: true
             )
  end

  test "uses default arities for capabilities and decisions" do
    assert is_function(ReqLLM.llm(), 3)

    response =
      FakeGeneration.response(
        Jidoka.Config.normalize_model_spec!(%{provider: :test, id: "decision"}),
        ~s({"type":"final","content":"done"})
      )

    assert {:ok, %{type: :final, content: "done"}} = ReqLLM.decision(response)
  end

  defp llm_intent do
    Effect.Intent.new(:llm, %{
      agent_id: "agent-1",
      request_id: "request-1",
      loop_index: 0,
      prompt: %{messages: [%{role: :user, content: "Reply."}], operations: []}
    })
  end
end
