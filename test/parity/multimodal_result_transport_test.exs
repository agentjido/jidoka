defmodule Jidoka.Parity.MultimodalResultTransportTest do
  use Jidoka.ParityCase, parity: :multimodal_result_transport

  alias Jidoka.Agent.Spec
  alias Jidoka.ContentPart
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.ReqLLM
  alias Jidoka.Turn

  @private_image "private-image-bytes"

  @tag :a09
  test "typed media crosses prompts, results, snapshots, and safe projections" do
    input = [
      ContentPart.text("Review all supplied media."),
      ContentPart.image({:data, @private_image}, media_type: "image/png"),
      ContentPart.audio({:data, "audio-bytes"}, media_type: "audio/mpeg"),
      ContentPart.video({:url, "https://example.test/video.mp4"}, media_type: "video/mp4"),
      ContentPart.document({:file_id, "document-private"}, media_type: "application/pdf")
    ]

    test_pid = self()

    llm = fn intent, _journal, _context ->
      send(test_pid, {:multimodal_prompt, intent.payload.prompt})

      {:ok,
       %{
         type: :final,
         content: "Media reviewed.",
         parts: [
           ContentPart.text("Media reviewed."),
           ContentPart.image({:data, "result-image"}, media_type: "image/png")
         ]
       }}
    end

    assert {:ok, %Turn.Result{} = result} = Jidoka.turn(spec(), input, llm: llm)
    assert_receive {:multimodal_prompt, prompt}

    user = List.last(prompt.messages)
    assert Enum.map(user.content, & &1.type) == [:text, :image, :audio, :video, :document]
    assert Enum.map(result.parts, & &1.type) == [:text, :image]

    assert {:ok, req_messages} = ReqLLM.messages(prompt)
    req_user = Enum.find(req_messages, &(&1.role == :user))
    assert Enum.map(req_user.content, & &1.type) == [:text, :image, :file, :video_url, :file]

    projection = inspect(Jidoka.project(result), limit: :infinity)
    refute projection =~ @private_image
    refute projection =~ "document-private"
    refute projection =~ "result-image"

    checkpoint_llm = fn _intent, _journal, _context ->
      flunk("the checkpoint must pause before model execution")
    end

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(spec(), input, llm: checkpoint_llm, checkpoint: :after_prompt)

    assert {:ok, serialized} = AgentSnapshot.serialize(snapshot)
    assert {:ok, restored} = AgentSnapshot.deserialize(serialized)
    assert [%ContentPart{text: "Review all supplied media."} | _rest] = restored.turn_state.request.content

    restored_user = List.last(restored.turn_state.prompt.messages)
    assert restored_user.role == :user
    assert Enum.at(restored_user.content, 1).data == @private_image
  end

  defp spec do
    Spec.new!(
      id: "multimodal_result_transport_agent",
      instructions: "Review typed media and return typed content parts.",
      model: %{provider: :test, id: "multimodal"}
    )
  end
end
