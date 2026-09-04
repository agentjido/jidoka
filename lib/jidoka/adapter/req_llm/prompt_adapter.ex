defmodule Jidoka.Adapter.ReqLLM.PromptAdapter do
  @moduledoc false

  alias Jidoka.ContentPart
  alias Jidoka.Schema
  alias ReqLLM.Context, as: LLMContext
  alias ReqLLM.Message.ContentPart, as: LLMContentPart

  @spec build(map()) :: {:ok, [ReqLLM.Message.t()]} | {:error, term()}
  def build(prompt) when is_map(prompt) do
    prompt_messages = Schema.get_key(prompt, :messages, [])

    with true <- is_list(prompt_messages) or {:error, {:invalid_prompt_messages, prompt_messages}},
         {:ok, messages} <- convert_messages(prompt_messages) do
      contract =
        prompt
        |> Map.delete(:messages)
        |> Map.delete("messages")
        # `loop_index` is runtime bookkeeping, not an instruction to the model,
        # and it is the one key here that changes on every step of a turn. Because
        # this contract is encoded into a system message that precedes every other
        # message, leaving it in makes the request's leading bytes differ each
        # step, which defeats provider prompt caching for the whole prefix behind
        # it - the agent instructions and the user message included. The runtime
        # keeps its own copy: `Spine.Steps.plan_model_effect/1` puts `loop_index`
        # in the effect payload and names it in the idempotency key, and
        # `Turn.Result`'s debug metadata still reads it off the prompt map, so
        # dropping it here costs no behaviour.
        |> Map.delete(:loop_index)
        |> Map.delete("loop_index")
        |> Jason.encode!()

      messages =
        [
          LLMContext.system(runtime_system_prompt(prompt)),
          LLMContext.system("Jidoka turn contract:\n" <> contract)
          | messages
        ]

      validate_messages(messages)
    end
  rescue
    exception -> {:error, {:invalid_prompt_payload, exception}}
  end

  defp convert_messages(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, converted} ->
      case convert_message(message) do
        {:ok, req_message} -> {:cont, {:ok, [req_message | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_message(message) when is_map(message) do
    role = Schema.get_key(message, :role)
    content = Schema.get_key(message, :content)
    metadata = Schema.get_key(message, :metadata, %{})

    case role do
      role when role in [:assistant, "assistant"] ->
        convert_assistant_tool_calls(message, content, metadata)

      role when role in [:system, "system", :user, "user", :assistant, "assistant"] ->
        with {:ok, parts} <- convert_content(content) do
          {:ok, LLMContext.build(normalize_role(role), parts, metadata)}
        end

      role when role in [:tool, "tool"] ->
        convert_tool_message(message, metadata)

      other ->
        {:error, {:invalid_prompt_message_role, other}}
    end
  end

  defp convert_message(message), do: {:error, {:invalid_prompt_message, message}}

  defp convert_assistant_tool_calls(message, content, metadata) do
    calls = Schema.get_key(message, :tool_calls, [])

    if native_tool_calls?(calls) do
      with {:ok, tool_calls} <- req_tool_calls(calls),
           {:ok, reasoning_details} <- reasoning_details(message) do
        provider_metadata = Schema.get_key(message, :provider_metadata, %{})
        message_metadata = provider_metadata |> Schema.get_key(:message_metadata, %{}) |> ensure_map()

        req_message =
          LLMContext.assistant(content || "",
            tool_calls: tool_calls,
            metadata: Map.merge(message_metadata, metadata)
          )

        {:ok, %{req_message | reasoning_details: reasoning_details}}
      end
    else
      with {:ok, parts} <- convert_content(content) do
        {:ok, LLMContext.build(:assistant, parts, metadata)}
      end
    end
  end

  defp convert_tool_message(message, metadata) do
    case Schema.get_key(message, :tool_call_id) do
      id when is_binary(id) and id != "" ->
        name = Schema.get_key(message, :provider_name, Schema.get_key(message, :operation))
        output = Schema.get_key(message, :output, Schema.get_key(message, :content, ""))
        req_message = LLMContext.tool_result(id, name, output)
        {:ok, %{req_message | metadata: Map.merge(req_message.metadata, metadata)}}

      _missing ->
        {:ok,
         LLMContext.user(tool_observation(message),
           metadata: Map.put(metadata, :jidoka_original_role, :tool)
         )}
    end
  end

  defp native_tool_calls?([_ | _] = calls) do
    Enum.all?(calls, fn call ->
      case Schema.get_key(call, :provider_call_id) do
        id when is_binary(id) -> id != ""
        _other -> false
      end
    end)
  end

  defp native_tool_calls?(_calls), do: false

  defp req_tool_calls(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, converted} ->
      case req_tool_call(call) do
        {:ok, tool_call} -> {:cont, {:ok, [tool_call | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp req_tool_call(call) when is_map(call) do
    id = Schema.get_key(call, :provider_call_id)
    name = Schema.get_key(call, :provider_name, Schema.get_key(call, :name))
    arguments = Schema.get_key(call, :arguments, %{})
    provider_metadata = Schema.get_key(call, :provider_metadata, %{})

    with true <- (is_binary(id) and id != "") or {:error, {:invalid_provider_call_id, id}},
         true <- (is_binary(name) and name != "") or {:error, {:invalid_provider_tool_name, name}},
         {:ok, encoded} <- Jason.encode(arguments) do
      tool_call = ReqLLM.ToolCall.new(id, name, encoded)
      {:ok, ReqLLM.ToolCall.put_metadata(tool_call, provider_metadata)}
    end
  end

  defp req_tool_call(call), do: {:error, {:invalid_prompt_tool_call, call}}

  defp reasoning_details(message) do
    provider_metadata = Schema.get_key(message, :provider_metadata, %{})

    case Schema.get_key(provider_metadata, :reasoning_details) do
      nil -> {:ok, nil}
      details when is_list(details) -> normalize_reasoning_details(details)
      details -> {:error, {:invalid_reasoning_details, details}}
    end
  end

  defp normalize_reasoning_details(details) do
    details
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {detail, index}, {:ok, normalized} ->
      case reasoning_detail(detail, index) do
        {:ok, detail} -> {:cont, {:ok, [detail | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp reasoning_detail(%ReqLLM.Message.ReasoningDetails{} = detail, _index), do: {:ok, detail}

  defp reasoning_detail(detail, index) when is_map(detail) do
    {:ok,
     %ReqLLM.Message.ReasoningDetails{
       text: Schema.get_key(detail, :text),
       signature: Schema.get_key(detail, :signature),
       encrypted?: Schema.get_key(detail, :encrypted?, false),
       provider: reasoning_provider(Schema.get_key(detail, :provider)),
       format: Schema.get_key(detail, :format),
       index: Schema.get_key(detail, :index, index),
       provider_data: Schema.get_key(detail, :provider_data, %{})
     }}
  end

  defp reasoning_detail(detail, _index), do: {:error, {:invalid_reasoning_detail, detail}}

  defp reasoning_provider(provider) when is_atom(provider), do: provider

  defp reasoning_provider(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  defp reasoning_provider(_provider), do: nil

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp validate_messages(messages) do
    case LLMContext.normalize(messages) do
      {:ok, context} -> {:ok, context.messages}
      {:error, reason} -> {:error, {:invalid_provider_continuation, reason}}
    end
  end

  defp convert_content(content) when is_binary(content), do: {:ok, [LLMContentPart.text(content)]}

  defp convert_content(content) when is_list(content) and content != [] do
    content
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, converted} ->
      with {:ok, part} <- ContentPart.from_input(part),
           {:ok, req_part} <- to_req_content_part(part) do
        {:cont, {:ok, [req_part | converted]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp convert_content(content), do: {:error, {:invalid_prompt_message_content, content}}

  defp to_req_content_part(%ContentPart{type: :text, text: text, metadata: metadata}),
    do: {:ok, LLMContentPart.text(text, metadata)}

  defp to_req_content_part(%ContentPart{type: :image} = part) do
    case ContentPart.source_kind(part) do
      :url -> {:ok, req_media_url(part, :image_url)}
      :data -> {:ok, req_image(part)}
      :file_id -> {:ok, req_file_id(part)}
    end
  end

  defp to_req_content_part(%ContentPart{type: :video} = part) do
    case ContentPart.source_kind(part) do
      :url -> {:ok, req_media_url(part, :video_url)}
      :data -> {:ok, req_file(part)}
      :file_id -> {:ok, req_file_id(part)}
    end
  end

  defp to_req_content_part(%ContentPart{type: type} = part)
       when type in [:audio, :document] do
    case ContentPart.source_kind(part) do
      :data -> {:ok, req_file(part)}
      :file_id -> {:ok, req_file_id(part)}
      :url -> {:error, {:unsupported_media_source, type, :url}}
    end
  end

  defp req_file(%ContentPart{} = part) do
    part.data
    |> LLMContentPart.file(part.filename || default_filename(part.type), part.media_type)
    |> Map.put(:metadata, part.metadata)
  end

  defp req_image(%ContentPart{} = part) do
    part.data
    |> LLMContentPart.image(part.media_type, part.metadata)
    |> Map.put(:filename, part.filename)
  end

  defp req_media_url(%ContentPart{} = part, type) do
    req_part =
      case type do
        :image_url -> LLMContentPart.image_url(part.url, media_metadata(part))
        :video_url -> LLMContentPart.video_url(part.url, media_metadata(part))
      end

    %LLMContentPart{req_part | media_type: part.media_type, filename: part.filename}
  end

  defp req_file_id(%ContentPart{} = part) do
    part.file_id
    |> LLMContentPart.file_id(part.media_type, part.metadata)
    |> Map.put(:filename, part.filename)
  end

  defp media_metadata(%ContentPart{} = part) do
    part.metadata
    |> maybe_put(:media_type, part.media_type)
    |> maybe_put(:filename, part.filename)
  end

  defp default_filename(:audio), do: "audio"
  defp default_filename(:video), do: "video"
  defp default_filename(:document), do: "document"

  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role(role) when is_binary(role), do: String.to_existing_atom(role)

  defp tool_observation(message) do
    operation = Schema.get_key(message, :operation, "operation")
    content = Schema.get_key(message, :content)
    output = Schema.get_key(message, :output)

    observation =
      cond do
        is_binary(content) -> content
        not is_nil(output) -> encode_observation(output)
        true -> ""
      end

    "Tool observation for #{operation}: #{observation}"
  end

  defp encode_observation(output) do
    case Jason.encode(output) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(output)
    end
  end

  defp runtime_system_prompt(prompt) do
    operation_instructions =
      if operations_available?(prompt) do
        """

        To call an available operation:
        {"type":"operation","name":"operation_name","arguments":{}}

        To call multiple independent operations in the same turn:
        {"type":"operations","operations":[{"name":"first_operation","arguments":{}},{"name":"second_operation","arguments":{}}]}

        Use only operations listed in the prompt payload. Never invent operation
        names. If a tool observation is present in the message history, use it
        to produce the final answer.
        """
      else
        """

        This prompt payload has no available operations. Never return an
        operation decision. Continue the conversation by returning a final
        answer, including clarifying questions when the task requires them.
        """
      end

    """
    You are the model side of a Jidoka agent turn.

    Return exactly one JSON object and no markdown.

    To answer the user directly:
    {"type":"final","content":"your answer"}

    If the prompt payload includes a non-null "result" contract, include a
    "result" field with the structured application value. Follow the result
    schema fields exactly:
    {"type":"final","content":"short user-facing answer","result":{}}
    #{operation_instructions}
    """
  end

  defp operations_available?(prompt) do
    case Schema.get_key(prompt, :operations) do
      operations when is_list(operations) -> operations != []
      _other -> false
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
