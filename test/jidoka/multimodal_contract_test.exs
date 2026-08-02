defmodule Jidoka.MultimodalContractTest.Support.Agent do
  use Jidoka.Agent

  agent :multimodal_contract_agent do
    model %{provider: :test, id: "model"}
    instructions "Inspect the supplied content and answer clearly."
  end
end

defmodule Jidoka.MultimodalContractTest do
  use ExUnit.Case, async: true

  alias Elixir.ReqLLM.Context, as: LLMContext
  alias Elixir.ReqLLM.Error.Invalid.Provider, as: InvalidProviderError
  alias Elixir.ReqLLM.Message.ContentPart, as: LLMContentPart
  alias Elixir.ReqLLM.Response, as: LLMResponse

  alias Jidoka.Agent.Message
  alias Jidoka.Agent.Spec.Generation
  alias Jidoka.ContentPart
  alias Jidoka.Effect
  alias Jidoka.MultimodalContractTest.Support.Agent
  alias Jidoka.Snapshot
  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Turn

  @input_bytes "private-image-input"
  @output_bytes "private-image-output"

  test "content parts validate one typed source and project it safely" do
    part =
      ContentPart.image({:data, @input_bytes},
        media_type: "image/png",
        filename: "diagram.png",
        metadata: %{authorization: "private-token", detail: "high"}
      )

    assert ContentPart.source_kind(part) == :data
    assert ContentPart.summary([part]) == "[Multimodal input: image]"

    assert Jidoka.project(part) == %{
             type: :image,
             source: :data,
             media_type: "image/png",
             filename: "diagram.png",
             byte_size: byte_size(@input_bytes),
             metadata: %{authorization: "[REDACTED]", detail: "high"}
           }

    assert {:error, {:invalid_content_part_source_count, :image, 2}} =
             ContentPart.new(type: :image, url: "https://example.test/image.png", data: "data")

    assert {:error, :empty_text_content_part} = ContentPart.new(type: :text, text: " ")
  end

  test "typed input and output survive a complete direct turn" do
    test_pid = self()

    input = [
      ContentPart.text("Describe this image."),
      ContentPart.image({:data, @input_bytes},
        media_type: "image/png",
        filename: "input.png"
      ),
      ContentPart.audio({:file_id, "audio-file-private"}, media_type: "audio/mpeg")
    ]

    llm = fn intent, _journal, _context ->
      send(test_pid, {:llm_prompt, intent.payload.prompt})

      {:ok,
       %{
         type: :final,
         content: "The image is ready.",
         parts: [
           ContentPart.text("The image is ready."),
           ContentPart.image({:data, @output_bytes},
             media_type: "image/png",
             filename: "result.png",
             metadata: %{provider_asset: "asset-123"}
           )
         ]
       }}
    end

    assert {:ok, %Turn.Result{} = result} = Jidoka.turn(Agent, input, llm: llm)
    assert result.content == "The image is ready."
    assert Enum.map(result.parts, & &1.type) == [:text, :image]
    assert List.last(result.parts).data == @output_bytes

    assert_receive {:llm_prompt, prompt}
    user_message = List.last(prompt.messages)
    assert Enum.map(user_message.content, & &1.type) == [:text, :image, :audio]
    assert Enum.at(user_message.content, 1).data == @input_bytes

    assert %Message{role: :assistant} = assistant = List.last(result.agent_state.messages)
    assert assistant.parts == result.parts

    finished = Enum.find(result.events, &(&1.event == :turn_finished))
    assert get_in(finished.data, [:parts, Access.at(1), :source]) == :data
    refute inspect(finished, limit: :infinity) =~ @output_bytes

    projected = Jidoka.project(result)
    projected_text = inspect(projected, limit: :infinity)
    refute projected_text =~ @input_bytes
    refute projected_text =~ @output_bytes
    refute projected_text =~ "audio-file-private"
    assert get_in(projected, [:parts, Access.at(1), :byte_size]) == byte_size(@output_bytes)
  end

  test "signed snapshots preserve media but public projections omit it" do
    input = [
      ContentPart.image({:data, @input_bytes},
        media_type: "image/png",
        filename: "snapshot.png"
      )
    ]

    llm = fn _intent, _journal, _context -> flunk("checkpoint must run before the LLM") end

    assert {:hibernate, %Snapshot{} = snapshot} =
             Jidoka.turn(Agent, input, llm: llm, checkpoint: :after_prompt)

    serialized = Snapshot.serialize!(snapshot)
    assert {:ok, restored} = Snapshot.deserialize(serialized)

    assert [%ContentPart{data: @input_bytes}] = restored.turn_state.request.content

    restored_user = List.last(restored.turn_state.prompt.messages)
    assert [%ContentPart{type: :image, data: @input_bytes}] = restored_user.content

    projected = inspect(Jidoka.project(restored), limit: :infinity)
    refute projected =~ @input_bytes
    assert projected =~ "byte_size"
  end

  test "process-hosted turns accept typed content parts" do
    id = "multimodal_contract_#{System.unique_integer([:positive])}"
    test_pid = self()

    assert {:ok, pid} = Agent.start(id: id)
    on_exit(fn -> Jidoka.stop_agent(pid) end)

    input = [ContentPart.image({:data, @input_bytes}, media_type: "image/png")]

    llm = fn intent, _journal, _context ->
      send(test_pid, {:hosted_prompt, intent.payload.prompt})
      {:ok, %{type: :final, content: "Hosted media accepted."}}
    end

    assert {:ok, %Turn.Result{content: "Hosted media accepted."}} =
             Jidoka.turn(pid, input, llm: llm)

    assert_receive {:hosted_prompt, prompt}
    assert [%ContentPart{type: :image, data: @input_bytes}] = List.last(prompt.messages).content
  end

  test "ReqLLM messages preserve native media fields and tool observations" do
    image =
      ContentPart.image({:data, @input_bytes},
        media_type: "image/png",
        filename: "input.png",
        metadata: %{detail: "high"}
      )

    prompt = %{
      model: "test:model",
      messages: [
        Message.system("System instruction") |> Message.to_map(),
        Message.user([
          ContentPart.text("Inspect this."),
          image,
          ContentPart.audio({:data, "audio-input"},
            media_type: "audio/mpeg",
            filename: "input.mp3"
          ),
          ContentPart.video({:url, "https://example.test/input.mp4"},
            media_type: "video/mp4"
          ),
          ContentPart.document({:file_id, "document-file-id"},
            media_type: "application/pdf",
            filename: "input.pdf"
          )
        ])
        |> Message.to_map(),
        Message.tool("lookup", %{status: "ok"}) |> Message.to_map()
      ],
      operations: []
    }

    assert {:ok, [runtime, contract, system, user, observation]} = ReqLLM.messages(prompt)
    assert runtime.role == :system
    assert contract.role == :system
    assert system.role == :system
    assert user.role == :user
    assert Enum.map(user.content, & &1.type) == [:text, :image, :file, :video_url, :file]

    req_image = Enum.at(user.content, 1)
    assert req_image.data == @input_bytes
    assert req_image.media_type == "image/png"
    assert req_image.metadata == %{detail: "high"}

    req_audio = Enum.at(user.content, 2)
    assert req_audio.data == "audio-input"
    assert req_audio.filename == "input.mp3"
    assert req_audio.media_type == "audio/mpeg"

    req_video = Enum.at(user.content, 3)
    assert req_video.url == "https://example.test/input.mp4"
    assert req_video.media_type == "video/mp4"

    req_document = Enum.at(user.content, 4)
    assert req_document.file_id == "document-file-id"
    assert req_document.filename == "input.pdf"
    assert req_document.media_type == "application/pdf"

    assert observation.role == :user
    assert Enum.map_join(observation.content, & &1.text) =~ "Tool observation for lookup"
  end

  test "ReqLLM reports sources it cannot represent without changing provider errors" do
    prompt = %{
      messages: [
        Message.user([
          ContentPart.audio({:url, "https://example.test/audio.mp3"}, media_type: "audio/mpeg")
        ])
        |> Message.to_map()
      ],
      operations: []
    }

    assert {:error, {:unsupported_media_source, :audio, :url}} = ReqLLM.messages(prompt)

    intent =
      Effect.Intent.new(:llm, %{
        model: %{provider: :test, id: "model"},
        generation: Generation.new!(),
        prompt: %{messages: [%{role: :user, content: "hello"}], operations: []}
      })

    assert {:error, %InvalidProviderError{provider: :test}} =
             ReqLLM.generate(intent, Effect.Journal.new!(), [])
  end

  test "ReqLLM output parts and provider metadata enter the result contract" do
    response = %LLMResponse{
      id: "response-123",
      model: "openai:image-model",
      context: %LLMContext{},
      message:
        LLMContext.assistant([
          LLMContentPart.text(~s({"type":"final","content":"Created."})),
          LLMContentPart.image(@output_bytes, "image/png", %{revised_prompt: "safe prompt"}),
          LLMContentPart.file("audio-output", "answer.mp3", "audio/mpeg"),
          LLMContentPart.video_url("https://example.test/output.mp4", %{media_type: "video/mp4"}),
          LLMContentPart.file_id("document-output-id", "application/pdf", %{title: "report"})
          |> Map.put(:filename, "report.pdf")
        ]),
      usage: %{input_tokens: 3, output_tokens: 4},
      finish_reason: :stop,
      provider_meta: %{"request_id" => "provider-request-123"}
    }

    {:ok, model} = Jidoka.Config.normalize_model_spec("openai:gpt-4o-mini")

    assert {:ok, decision} = ReqLLM.decision(response, model)
    assert decision.content == "Created."
    assert Enum.map(decision.parts, & &1.type) == [:text, :image, :audio, :video, :document]
    assert Enum.at(decision.parts, 1).data == @output_bytes
    assert Enum.at(decision.parts, 2).filename == "answer.mp3"
    assert Enum.at(decision.parts, 3).url == "https://example.test/output.mp4"
    assert List.last(decision.parts).file_id == "document-output-id"
    assert List.last(decision.parts).filename == "report.pdf"
    assert decision.metadata.provider == :openai
    assert decision.metadata.response_model == "openai:image-model"
    assert decision.metadata.provider_meta == %{"request_id" => "provider-request-123"}
    assert decision.metadata.finish_reason == :stop

    text_response = %LLMResponse{
      response
      | message: LLMContext.assistant(~s({"type":"final","content":"Text only."}))
    }

    assert {:ok, %{content: "Text only.", parts: []}} = ReqLLM.decision(text_response, model)
  end
end
