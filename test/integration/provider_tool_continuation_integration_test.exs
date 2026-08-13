defmodule Jidoka.ProviderToolContinuationIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Adapter.ReqLLM
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Runtime.LocalOperations

  @providers [:openai, :anthropic, :google]

  test "provider fixtures complete duplicate parallel calls with matched result IDs" do
    Enum.each(@providers, &assert_provider_loop/1)
  end

  test "provider fixtures complete dependent calls across model steps" do
    Enum.each(@providers, &assert_dependent_provider_loop/1)
  end

  defp assert_dependent_provider_loop(provider) do
    test_pid = self()
    provider_name = ToolProjection.provider_name("coding.read")
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn intent, _journal, _context ->
      step = Elixir.Agent.get_and_update(counter, &{&1, &1 + 1})

      case step do
        0 ->
          {:ok,
           Effect.LLMDecision.operation("coding.read", %{"path" => "one"},
             provider_call_id: "#{provider}-dependent-1",
             provider_metadata: provider_call_metadata(provider_name, provider, 1),
             metadata: continuation_metadata(provider)
           )}

        1 ->
          {:ok, messages} = ReqLLM.messages(intent.payload)
          send(test_pid, {:dependent_messages, provider, 1, messages})

          {:ok,
           Effect.LLMDecision.operation("coding.read", %{"path" => "two"},
             provider_call_id: "#{provider}-dependent-2",
             provider_metadata: provider_call_metadata(provider_name, provider, 2),
             metadata: continuation_metadata(provider)
           )}

        2 ->
          {:ok, messages} = ReqLLM.messages(intent.payload)
          send(test_pid, {:dependent_messages, provider, 2, messages})
          {:ok, Effect.LLMDecision.final("#{provider} dependent complete")}
      end
    end

    operations =
      LocalOperations.operations(%{
        "coding.read" => fn %{"path" => path}, _context -> %{path: path, provider: provider} end
      })

    assert {:ok, result} =
             Jidoka.turn(spec(provider), "Read in order", llm: llm, operations: operations)

    assert result.content == "#{provider} dependent complete"
    assert_received {:dependent_messages, ^provider, 1, first_messages}
    assert_received {:dependent_messages, ^provider, 2, second_messages}
    assert length(Enum.filter(first_messages, &(&1.role == :assistant and is_list(&1.tool_calls)))) == 1
    assert length(Enum.filter(first_messages, &(&1.role == :tool))) == 1
    assert length(Enum.filter(second_messages, &(&1.role == :assistant and is_list(&1.tool_calls)))) == 2
    assert length(Enum.filter(second_messages, &(&1.role == :tool))) == 2
  end

  defp assert_provider_loop(provider) do
    test_pid = self()
    provider_name = ToolProjection.provider_name("coding.read")
    call_ids = ["#{provider}-call-1", "#{provider}-call-2"]
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)

    llm = fn intent, _journal, _context ->
      case Elixir.Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          {:ok,
           Effect.LLMDecision.operations(
             [
               native_request("one", Enum.at(call_ids, 0), provider_name, provider),
               native_request("two", Enum.at(call_ids, 1), provider_name, provider)
             ],
             metadata: continuation_metadata(provider)
           )}

        1 ->
          {:ok, messages} = ReqLLM.messages(intent.payload)
          send(test_pid, {:provider_messages, provider, messages})
          {:ok, Effect.LLMDecision.final("#{provider} complete")}
      end
    end

    operations =
      LocalOperations.operations(%{
        "coding.read" => fn %{"path" => path}, _context -> %{path: path, provider: provider} end
      })

    assert {:ok, result} =
             Jidoka.turn(spec(provider), "Read both files", llm: llm, operations: operations)

    assert result.content == "#{provider} complete"
    assert_received {:provider_messages, ^provider, messages}

    assistant = Enum.find(messages, &(&1.role == :assistant and is_list(&1.tool_calls)))
    tool_results = Enum.filter(messages, &(&1.role == :tool))

    assert Enum.map(assistant.tool_calls, & &1.id) == call_ids
    assert Enum.map(assistant.tool_calls, & &1.function.name) == [provider_name, provider_name]
    assert Enum.map(tool_results, & &1.tool_call_id) == call_ids
    assert Enum.map(tool_results, & &1.name) == [provider_name, provider_name]
    assert Enum.map(assistant.reasoning_details, & &1.provider) == [provider]
    assert Enum.map(assistant.reasoning_details, & &1.signature) == ["#{provider}-signature"]
    assert_provider_encoding(provider, assistant, tool_results, call_ids)

    if provider == :google do
      assert Enum.map(assistant.tool_calls, &Elixir.ReqLLM.ToolCall.metadata/1) == [
               %{provider_tool_name: provider_name, thought_signature: "google-thought-1"},
               %{provider_tool_name: provider_name, thought_signature: "google-thought-2"}
             ]
    end
  end

  defp assert_provider_encoding(:openai, assistant, tool_results, call_ids) do
    encoded =
      Elixir.ReqLLM.Provider.Defaults.encode_context_to_openai_format(
        %Elixir.ReqLLM.Context{messages: [assistant | tool_results]},
        "fixture-model",
        encode_reasoning_details?: true
      )

    [assistant_message | result_messages] = encoded.messages
    assert Enum.map(assistant_message.tool_calls, & &1.id) == call_ids
    assert Enum.map(result_messages, & &1.tool_call_id) == call_ids
  end

  defp assert_provider_encoding(:anthropic, assistant, tool_results, call_ids) do
    encoded = provider_body(:anthropic, assistant, tool_results)

    Enum.each(call_ids, &assert(String.contains?(encoded, &1)))
    assert String.contains?(encoded, "anthropic-signature")
  end

  defp assert_provider_encoding(:google, assistant, tool_results, _call_ids) do
    encoded = provider_body(:google, assistant, tool_results)

    assert length(Regex.scan(~r/"functionCall"/, encoded)) == 2
    assert length(Regex.scan(~r/"functionResponse"/, encoded)) == 2
    assert String.contains?(encoded, "google-signature")
    assert String.contains?(encoded, "google-thought-1")
    assert String.contains?(encoded, "google-thought-2")
  end

  defp provider_body(provider, assistant, tool_results) do
    assert {:ok, request} =
             provider_module(provider).prepare_request(
               :chat,
               provider_model(provider),
               [assistant | tool_results],
               api_key: "test-key",
               tools: []
             )

    encoded_request = provider_module(provider).encode_body(request)

    body =
      encoded_request.options
      |> Map.fetch!(:json)

    Jason.encode!(body)
  end

  defp provider_module(:anthropic), do: Elixir.ReqLLM.Providers.Anthropic
  defp provider_module(:google), do: Elixir.ReqLLM.Providers.Google

  defp provider_model(:anthropic),
    do: %{provider: :anthropic, id: "claude-sonnet-4-5-20250929"}

  defp provider_model(:google), do: %{provider: :google, id: "gemini-2.5-flash"}

  defp native_request(path, call_id, provider_name, provider) do
    index = if String.ends_with?(call_id, "1"), do: 1, else: 2

    %{
      name: "coding.read",
      arguments: %{"path" => path},
      provider_call_id: call_id,
      provider_metadata: provider_call_metadata(provider_name, provider, index)
    }
  end

  defp provider_call_metadata(provider_name, provider, index) do
    %{provider_tool_name: provider_name}
    |> maybe_put_thought_signature(provider, index)
  end

  defp continuation_metadata(provider) do
    %{
      assistant_text: "",
      message_metadata: %{provider_fixture: Atom.to_string(provider)},
      reasoning_details: [
        %{
          text: "",
          signature: "#{provider}-signature",
          encrypted?: true,
          provider: provider,
          format: "fixture-v1",
          index: 0,
          provider_data: %{}
        }
      ]
    }
  end

  defp maybe_put_thought_signature(metadata, :google, index),
    do: Map.put(metadata, :thought_signature, "google-thought-#{index}")

  defp maybe_put_thought_signature(metadata, _provider, _index), do: metadata

  defp spec(provider) do
    Agent.Spec.new!(
      id: "#{provider}-continuation-agent",
      instructions: "Read both files.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "coding.read",
          description: "Read one file.",
          idempotency: :pure,
          metadata: %{
            "parameters_schema" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}},
              "required" => ["path"],
              "additionalProperties" => false
            }
          }
        )
      ]
    )
  end
end
