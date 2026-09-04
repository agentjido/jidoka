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

  test "normalizes ReqLLM 1.21 prompt continuation variants" do
    assert {:error, {:invalid_prompt_payload, %Protocol.UndefinedError{}}} =
             Adapter.messages(%{messages: [], opaque: self()})

    prompt = %{
      messages: [
        %{
          role: :assistant,
          content: "plain assistant text",
          tool_calls: [%{provider_call_id: "", provider_name: "lookup", arguments: %{}}]
        },
        %{
          role: :assistant,
          content: "",
          tool_calls: [
            %{provider_call_id: "call-1", provider_name: "lookup", arguments: %{id: "A-1"}}
          ]
        },
        %{role: :user, content: [ContentPart.audio({:data, "audio-data"})]}
      ]
    }

    assert {:ok, [_runtime, _contract, assistant, continuation, user]} =
             Adapter.messages(prompt)

    assert text(assistant) == "plain assistant text"
    assert [%ReqLLM.ToolCall{id: "call-1"}] = continuation.tool_calls
    assert continuation.reasoning_details == nil
    assert [%ReqLLM.Message.ContentPart{type: :file, filename: "audio"}] = user.content
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

  alias Jidoka.Adapter.ReqLLM.PromptAdapter

  defp system_texts(prompt) do
    {:ok, messages} = PromptAdapter.build(prompt)

    messages
    |> Enum.filter(&(&1.role == :system))
    |> Enum.map(fn message -> Enum.map_join(message.content, "", & &1.text) end)
  end

  defp contract_prompt(extra) do
    Map.merge(%{messages: [%{role: :user, content: "hello"}]}, extra)
  end

  # WHY THIS TEST EXISTS: the encoded contract rides in a system message that
  # precedes every other message, so any key that changes per step makes the
  # request's leading bytes differ each step and defeats provider prompt caching
  # for the entire prefix behind it. `loop_index` was the only such key.
  test "the encoded contract is byte-identical across steps of a turn" do
    assert system_texts(contract_prompt(%{loop_index: 0})) ==
             system_texts(contract_prompt(%{loop_index: 7}))
  end

  test "a string-keyed loop_index is excluded too" do
    assert system_texts(contract_prompt(%{"loop_index" => 0})) ==
             system_texts(contract_prompt(%{"loop_index" => 3}))
  end

  # WHY THIS TEST EXISTS: excluding one key must not silence the rest of the
  # contract, which the model does act on.
  test "the remaining contract keys still reach the model" do
    [_runtime, contract] =
      system_texts(contract_prompt(%{loop_index: 2, result: %{shape: "report"}}))

    assert contract =~ "result"
    assert contract =~ "report"
    refute contract =~ "loop_index"
  end
end
