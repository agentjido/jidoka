defmodule Jidoka.Adapter.ReqLLM.PromptAdapterTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM, as: Adapter
  alias Jidoka.ContentPart

  test "rejects invalid prompt and message shapes" do
    assert {:error, {:invalid_prompt_messages, :invalid}} =
             Adapter.messages(%{messages: :invalid})

    assert {:error, {:invalid_prompt_message, :invalid}} =
             Adapter.messages(%{messages: [:invalid]})

    assert {:error, {:invalid_prompt_message_role, :invalid}} =
             Adapter.messages(%{messages: [%{role: :invalid, content: "bad"}]})

    assert {:error, {:invalid_prompt_message_content, []}} =
             Adapter.messages(%{messages: [%{role: :user, content: []}]})

    assert {:error, {:invalid_prompt_payload, "invalid"}} =
             Adapter.messages(%{prompt: "invalid"})
  end

  test "preserves native tool calls, reasoning, and tool results" do
    reasoning = %ReqLLM.Message.ReasoningDetails{
      text: "considered",
      signature: "sig-1",
      encrypted?: false,
      provider: :openai,
      format: "fixture",
      index: 0,
      provider_data: %{}
    }

    prompt = %{
      messages: [
        %{
          role: :assistant,
          content: nil,
          metadata: %{local: true},
          tool_calls: [
            %{
              provider_call_id: "call-1",
              provider_name: "lookup",
              arguments: %{id: "A-1"},
              provider_metadata: %{thought_signature: "thought-1"}
            }
          ],
          provider_metadata: %{
            message_metadata: :invalid,
            reasoning_details: [
              reasoning,
              %{
                text: "second",
                provider: "anthropic",
                encrypted?: true,
                provider_data: %{token: "safe"}
              },
              %{text: "unknown", provider: "provider_that_is_not_an_atom"},
              %{text: "invalid provider", provider: 123}
            ]
          }
        },
        %{
          role: :tool,
          tool_call_id: "call-1",
          provider_name: "lookup",
          output: %{found: true},
          metadata: %{source: "test"}
        }
      ],
      operations: [%{name: "lookup"}]
    }

    assert {:ok, [_runtime, _contract, assistant, tool]} = Adapter.messages(prompt)
    assert [%ReqLLM.ToolCall{id: "call-1"}] = assistant.tool_calls
    assert Enum.map(assistant.reasoning_details, & &1.provider) == [:openai, :anthropic, nil, nil]
    assert assistant.metadata == %{local: true}
    assert tool.role == :tool
    assert tool.metadata.source == "test"
  end

  test "reports invalid native continuation data" do
    base = %{
      role: :assistant,
      content: "",
      tool_calls: [%{provider_call_id: "call-1", provider_name: "lookup", arguments: %{}}]
    }

    assert {:error, {:invalid_provider_tool_name, nil}} =
             Adapter.messages(%{
               messages: [%{base | tool_calls: [%{provider_call_id: "call-1", arguments: %{}}]}]
             })

    assert {:error, {:invalid_reasoning_details, :invalid}} =
             Adapter.messages(%{
               messages: [Map.put(base, :provider_metadata, %{reasoning_details: :invalid})]
             })

    assert {:error, {:invalid_reasoning_detail, :invalid}} =
             Adapter.messages(%{
               messages: [Map.put(base, :provider_metadata, %{reasoning_details: [:invalid]})]
             })

    assert {:error, _reason} =
             Adapter.messages(%{
               messages: [
                 %{base | tool_calls: [%{provider_call_id: "call-1", provider_name: "lookup", arguments: self()}]}
               ]
             })
  end

  test "converts every supported media source into provider parts" do
    parts = [
      ContentPart.image({:url, "https://example.test/image.png"}, filename: "image.png"),
      ContentPart.image({:file_id, "image-file"}),
      ContentPart.video({:data, "video-data"}),
      ContentPart.video({:file_id, "video-file"}),
      ContentPart.audio({:file_id, "audio-file"}),
      ContentPart.document({:data, "document-data"})
    ]

    assert {:ok, [_runtime, _contract, user]} =
             Adapter.messages(%{messages: [%{role: "user", content: parts}]})

    assert Enum.map(user.content, & &1.type) == [
             :image_url,
             :file,
             :file,
             :file,
             :file,
             :file
           ]

    assert Enum.map(user.content, & &1.filename) == [
             "image.png",
             nil,
             "video",
             nil,
             nil,
             "document"
           ]
  end

  test "falls back to durable user observations for non-native tool history" do
    prompt = %{
      messages: [
        %{role: :tool, operation: "lookup", output: %{found: true}},
        %{role: :tool, operation: "inspect", output: self()},
        %{role: :tool, operation: "empty"}
      ]
    }

    assert {:ok, [_runtime, _contract, first, second, third]} = Adapter.messages(prompt)
    assert first.role == :user
    assert first.metadata.jidoka_original_role == :tool
    assert text(first) =~ ~s({"found":true})
    assert text(second) =~ inspect(self())
    assert text(third) == "Tool observation for empty: "
  end

  defp text(message), do: Enum.map_join(message.content, & &1.text)
end
