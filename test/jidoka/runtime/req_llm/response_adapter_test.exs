defmodule Jidoka.Adapter.ReqLLM.ResponseAdapterTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM.ResponseAdapter
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias ReqLLM.Context, as: LLMContext
  alias ReqLLM.Response, as: LLMResponse
  alias ReqLLM.ToolCall

  test "normalizes one native call with empty assistant text" do
    prompt = prompt(["coding.read"])

    call =
      ToolCall.new(
        "call-read-1",
        ToolProjection.provider_name("coding.read"),
        ~s({"path":"lib/jidoka.ex"})
      )

    assert {:ok, decision} =
             ResponseAdapter.decision(response([call]), nil, "", prompt: prompt)

    assert decision.type == :operation
    assert [request] = decision.operations
    assert request.name == "coding.read"
    assert request.arguments == %{"path" => "lib/jidoka.ex"}
    assert request.provider_call_id == "call-read-1"
    assert request.provider_metadata.provider_tool_name == call.function.name
  end

  test "preserves provider tool and reasoning continuation metadata" do
    provider_name = ToolProjection.provider_name("coding.read")

    call =
      ToolCall.new("call-google-1", provider_name, ~s({"path":"lib/jidoka.ex"}))
      |> ToolCall.put_metadata(%{thought_signature: "google-thought"})

    reasoning = %ReqLLM.Message.ReasoningDetails{
      text: "",
      signature: "google-reasoning",
      encrypted?: true,
      provider: :google,
      format: "fixture-v1",
      index: 0,
      provider_data: %{}
    }

    response = response([call])
    response = %{response | message: %{response.message | reasoning_details: [reasoning]}}

    assert {:ok, decision} =
             ResponseAdapter.decision(response, nil, "", prompt: prompt(["coding.read"]))

    assert [request] = decision.operations
    assert request.provider_metadata.thought_signature == "google-thought"
    assert request.provider_metadata.provider_tool_name == provider_name
    assert [detail] = decision.metadata.reasoning_details
    assert detail.signature == "google-reasoning"
    assert detail.provider == :google
    assert decision.metadata.assistant_text == ""
  end

  test "normalizes multiple native calls in provider order" do
    prompt = prompt(["lookup", "coding.read"])

    calls = [
      ToolCall.new("call-1", "lookup", ~s({"path":"one"})),
      ToolCall.new("call-2", ToolProjection.provider_name("coding.read"), ~s({"path":"two"}))
    ]

    assert {:ok, decision} =
             ResponseAdapter.decision(response(calls), nil, "", prompt: prompt)

    assert decision.type == :operations
    assert Enum.map(decision.operations, & &1.name) == ["lookup", "coding.read"]
    assert Enum.map(decision.operations, & &1.provider_call_id) == ["call-1", "call-2"]

    assert Enum.map(decision.operations, & &1.arguments) == [
             %{"path" => "one"},
             %{"path" => "two"}
           ]
  end

  test "native and JSON fallback protocols create the same operation records" do
    prompt = prompt(["lookup", "coding.read"])

    native =
      response([
        ToolCall.new("call-1", "lookup", ~s({"path":"one"})),
        ToolCall.new("call-2", ToolProjection.provider_name("coding.read"), ~s({"path":"two"}))
      ])

    fallback =
      response(
        [],
        ~s({"type":"operations","operations":[{"name":"lookup","arguments":{"path":"one"}},{"name":"coding.read","arguments":{"path":"two"}}]}),
        :stop
      )

    assert {:ok, native_decision} = ResponseAdapter.decision(native, nil, "", prompt: prompt)
    assert {:ok, fallback_decision} = ResponseAdapter.decision(fallback, nil)

    assert operation_contracts(native_decision) == operation_contracts(fallback_decision)
  end

  test "rejects incomplete, cancelled, filtered, and error responses" do
    assert {:error, {:llm_response_incomplete, :incomplete}} =
             ResponseAdapter.decision(response([], "", :incomplete), nil)

    assert {:error, {:llm_response_incomplete, :length}} =
             ResponseAdapter.decision(response([], "partial", :length), nil)

    assert {:error, :llm_response_cancelled} =
             ResponseAdapter.decision(response([], "", :cancelled), nil)

    assert {:error, {:llm_response_filtered, :content_filter}} =
             ResponseAdapter.decision(response([], "", :content_filter), nil)

    assert {:error, {:llm_response_error, :provider_finish_reason}} =
             ResponseAdapter.decision(response([], "", :error), nil)

    assert {:error, {:llm_response_error, :transport_failed}} =
             ResponseAdapter.decision(%LLMResponse{response([], "", :stop) | error: :transport_failed}, nil)
  end

  test "rejects empty finals and malformed native calls" do
    assert {:error, :empty_llm_response} = ResponseAdapter.decision(response([], "", :stop), nil)

    malformed = ToolCall.new("call-bad", "lookup", "{")

    assert {:error, {:invalid_native_tool_arguments, "lookup", _reason}} =
             ResponseAdapter.decision(response([malformed]), nil, "", prompt: prompt(["lookup"]))

    assert {:error, :empty_native_tool_calls} =
             ResponseAdapter.decision(response([], "", :tool_calls), nil, "", prompt: prompt(["lookup"]))
  end

  test "rejects provider tool names that are not in the turn registry" do
    call = ToolCall.new("call-unknown", "unknown", "{}")

    assert {:error, {:unknown_provider_tool_name, "unknown"}} =
             ResponseAdapter.decision(response([call]), nil, "", prompt: prompt(["lookup"]))
  end

  test "normalizes map-shaped native calls and direct argument maps" do
    calls = [
      %{
        id: "map-call-1",
        function: %{name: "lookup", arguments: %{"id" => "A-1"}},
        metadata: %{provider: :fixture}
      }
    ]

    assert {:ok, decision} =
             ResponseAdapter.decision(response_with_calls(calls), nil, "")

    assert [%{name: "lookup", arguments: %{"id" => "A-1"}} = request] = decision.operations
    assert request.provider_call_id == "map-call-1"
    assert request.provider_metadata.provider == :fixture
  end

  test "reports every malformed map-shaped native call field" do
    cases = [
      {%{id: "call-1", function: %{name: nil, arguments: %{}}}, {:invalid_native_tool_name, nil}},
      {%{id: "call-1", name: "lookup", arguments: "[]"}, {:invalid_native_tool_arguments, "lookup", []}},
      {%{id: "call-1", name: "lookup", arguments: 123}, {:invalid_native_tool_arguments, "lookup", 123}},
      {%{id: nil, name: "lookup", arguments: %{}}, {:invalid_native_tool_call_id, nil}},
      {%{id: "", name: "lookup", arguments: %{}}, {:invalid_native_tool_call_id, ""}},
      {%{id: 123, name: "lookup", arguments: %{}}, {:invalid_native_tool_call_id, 123}},
      {:invalid, {:invalid_native_tool_call, :invalid}}
    ]

    Enum.each(cases, fn {call, reason} ->
      assert {:error, ^reason} =
               ResponseAdapter.decision(response_with_calls([call]), nil, "")
    end)
  end

  test "validates explicit registry and prompt options" do
    call = ToolCall.new("call-1", "lookup", "{}")

    assert {:error, {:invalid_operation_registry, :invalid}} =
             ResponseAdapter.decision(response([call]), nil, "", registry: :invalid)

    assert {:error, {:invalid_prompt_payload, "invalid"}} =
             ResponseAdapter.decision(response([call]), nil, "", prompt: "invalid")
  end

  test "converts provider output files by media type and rejects bad parts" do
    good_parts = [
      ReqLLM.Message.ContentPart.image_url("https://example.test/image.png"),
      ReqLLM.Message.ContentPart.file("image", "image.png", "image/png"),
      ReqLLM.Message.ContentPart.file("video", "video.mp4", "video/mp4"),
      ReqLLM.Message.ContentPart.file("document", "document.bin", nil)
    ]

    good = %LLMResponse{
      response([], ~s({"type":"final","content":"parts"}), :stop)
      | message:
          LLMContext.assistant([
            ReqLLM.Message.ContentPart.text(~s({"type":"final","content":"parts"}))
            | good_parts
          ])
    }

    assert {:ok, decision} = ResponseAdapter.decision(good)
    assert Enum.map(decision.parts, & &1.type) == [:text, :image, :image, :video, :document]

    bad_type = %LLMResponse{
      good
      | message:
          LLMContext.assistant([
            ReqLLM.Message.ContentPart.text(~s({"type":"final","content":"parts"})),
            %ReqLLM.Message.ContentPart{type: :unknown}
          ])
    }

    assert {:error, {:unsupported_provider_content_part, :unknown}} =
             ResponseAdapter.decision(bad_type)

    bad_file = %LLMResponse{
      good
      | message:
          LLMContext.assistant([
            ReqLLM.Message.ContentPart.text(~s({"type":"final","content":"parts"})),
            %ReqLLM.Message.ContentPart{type: :file, media_type: "application/pdf"}
          ])
    }

    assert {:error, {:invalid_provider_file_part, _part}} =
             ResponseAdapter.decision(bad_file)
  end

  test "accepts an explicit registry and a nil text classification" do
    assert {:ok, registry} = ToolProjection.registry_from_prompt(prompt(["lookup"]))
    call = ToolCall.new("call-1", "lookup", %{} |> Jason.encode!())

    assert {:ok, %{operations: [%{name: "lookup"}]}} =
             ResponseAdapter.decision(response([call]), nil, nil, registry: registry)
  end

  defp response(calls, text \\ "", finish_reason \\ :tool_calls) do
    %LLMResponse{
      id: "response-1",
      model: "test:model",
      context: LLMContext.new([]),
      message: LLMContext.assistant(text, tool_calls: calls),
      finish_reason: finish_reason
    }
  end

  defp response_with_calls(calls) do
    %LLMResponse{
      id: "response-map-calls",
      model: "test:model",
      context: LLMContext.new([]),
      message: %ReqLLM.Message{role: :assistant, content: [], tool_calls: calls},
      finish_reason: :tool_calls
    }
  end

  defp prompt(names) do
    %{
      operations:
        Enum.map(names, fn name ->
          %{
            name: name,
            description: "Read one path.",
            idempotency: :pure,
            parameters_schema: %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"],
              "additionalProperties" => false
            }
          }
        end)
    }
  end

  defp operation_contracts(decision) do
    Enum.map(decision.operations, &Map.take(&1, [:name, :arguments]))
  end
end
