defmodule Jidoka.Adapter.ReqLLM.ResponseAdapter do
  @moduledoc false

  alias Jidoka.ContentPart
  alias Jidoka.Effect
  alias Jidoka.Adapter.ReqLLM.Decision
  alias Jidoka.Adapter.ReqLLM.ToolProjection
  alias Jidoka.Operation.Registry
  alias Jidoka.Schema
  alias ReqLLM.Message.ContentPart, as: LLMContentPart

  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(response, model \\ nil)

  def decision(%ReqLLM.Response{} = response, model) do
    decision(response, model, ReqLLM.Response.text(response), [])
  end

  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil, String.t() | nil) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(%ReqLLM.Response{} = response, model, text) do
    decision(response, model, text, [])
  end

  @doc false
  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(%ReqLLM.Response{} = response, model, text, opts) when is_list(opts) do
    classification = classification(response, text)

    with :ok <- validate_response(response, classification),
         {:ok, registry} <- response_registry(opts),
         {:ok, decision} <- classified_decision(response, classification, registry),
         {:ok, parts} <- response_content_parts(response) do
      {:ok,
       decision
       |> attach_output_parts(parts)
       |> attach_response_metadata(model, response)}
    end
  end

  defp classification(response, text) do
    classification = ReqLLM.Response.classify(response)

    if is_binary(text),
      do: Map.put(classification, :text, text),
      else: classification
  end

  defp validate_response(%ReqLLM.Response{error: error}, _classification) when not is_nil(error),
    do: {:error, {:llm_response_error, error}}

  defp validate_response(_response, %{finish_reason: :cancelled}),
    do: {:error, :llm_response_cancelled}

  defp validate_response(_response, %{finish_reason: reason}) when reason in [:incomplete, :length],
    do: {:error, {:llm_response_incomplete, reason}}

  defp validate_response(_response, %{finish_reason: :error}),
    do: {:error, {:llm_response_error, :provider_finish_reason}}

  defp validate_response(_response, %{finish_reason: :content_filter}),
    do: {:error, {:llm_response_filtered, :content_filter}}

  defp validate_response(_response, _classification), do: :ok

  defp response_registry(opts) do
    case Keyword.get(opts, :registry) do
      %Registry{} = registry -> {:ok, registry}
      nil -> registry_from_prompt(Keyword.get(opts, :prompt))
      registry -> {:error, {:invalid_operation_registry, registry}}
    end
  end

  defp registry_from_prompt(nil), do: {:ok, nil}
  defp registry_from_prompt(prompt) when is_map(prompt), do: ToolProjection.registry_from_prompt(prompt)
  defp registry_from_prompt(prompt), do: {:error, {:invalid_prompt_payload, prompt}}

  defp classified_decision(response, %{type: :tool_calls}, registry) do
    response
    |> ReqLLM.Response.tool_calls()
    |> Enum.reject(&non_application_call?/1)
    |> native_tool_decision(registry)
  end

  defp classified_decision(_response, %{type: :final_answer, text: text}, _registry) do
    case normalized_text(text) do
      "" -> {:error, :empty_llm_response}
      text -> Decision.parse_text(text)
    end
  end

  defp native_tool_decision([], _registry), do: {:error, :empty_native_tool_calls}

  defp native_tool_decision(calls, registry) do
    calls
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, requests} ->
      case native_operation_request(call, registry) do
        {:ok, request} -> {:cont, {:ok, [request | requests]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, [request]} -> {:ok, singular_native_decision(request)}
      {:ok, requests} -> {:ok, Effect.LLMDecision.operations(Enum.reverse(requests))}
      error -> error
    end
  end

  defp singular_native_decision(request) do
    Effect.LLMDecision.operation(request.name, request.arguments,
      provider_call_id: request.provider_call_id,
      provider_metadata: request.provider_metadata
    )
  end

  defp native_operation_request(call, registry) do
    with {:ok, provider_name} <- native_call_name(call),
         {:ok, name} <- canonical_name(registry, provider_name),
         {:ok, arguments} <- native_call_arguments(call),
         {:ok, provider_call_id} <- native_call_id(call) do
      Effect.OperationRequest.new(
        name: name,
        arguments: arguments,
        provider_call_id: provider_call_id,
        provider_metadata: native_call_metadata(call, provider_name)
      )
    end
  end

  defp native_call_name(%ReqLLM.ToolCall{} = call), do: non_empty_name(ReqLLM.ToolCall.name(call))

  defp native_call_name(call) when is_map(call) do
    function = Schema.get_key(call, :function, %{})
    non_empty_name(Schema.get_key(call, :name) || Schema.get_key(function, :name))
  end

  defp native_call_name(call), do: {:error, {:invalid_native_tool_call, call}}

  defp non_empty_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp non_empty_name(name), do: {:error, {:invalid_native_tool_name, name}}

  defp native_call_arguments(%ReqLLM.ToolCall{} = call) do
    decode_native_arguments(ReqLLM.ToolCall.args_json(call), ReqLLM.ToolCall.name(call))
  end

  defp native_call_arguments(call) when is_map(call) do
    function = Schema.get_key(call, :function, %{})
    arguments = Schema.get_key(call, :arguments, Schema.get_key(function, :arguments, %{}))
    name = Schema.get_key(call, :name) || Schema.get_key(function, :name)
    decode_native_arguments(arguments, name)
  end

  defp decode_native_arguments(arguments, _name) when is_map(arguments), do: {:ok, arguments}

  defp decode_native_arguments(arguments, name) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, arguments} -> {:error, {:invalid_native_tool_arguments, name, arguments}}
      {:error, reason} -> {:error, {:invalid_native_tool_arguments, name, reason}}
    end
  end

  defp decode_native_arguments(arguments, name),
    do: {:error, {:invalid_native_tool_arguments, name, arguments}}

  defp native_call_id(%ReqLLM.ToolCall{id: id}), do: optional_id(id)
  defp native_call_id(call) when is_map(call), do: optional_id(Schema.get_key(call, :id))

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(""), do: {:ok, nil}
  defp optional_id(id) when is_binary(id), do: {:ok, id}
  defp optional_id(id), do: {:error, {:invalid_native_tool_call_id, id}}

  defp canonical_name(nil, provider_name), do: {:ok, provider_name}
  defp canonical_name(%Registry{} = registry, provider_name), do: ToolProjection.canonical_name(registry, provider_name)

  defp native_call_metadata(call, provider_name) do
    call
    |> ReqLLM.ToolCall.metadata()
    |> Map.put_new(:provider_tool_name, provider_name)
  end

  defp non_application_call?(call),
    do: ReqLLM.ToolCall.builtin?(call) or ReqLLM.ToolCall.provider_native?(call)

  defp normalized_text(text) when is_binary(text), do: String.trim(text)
  defp normalized_text(_text), do: ""

  defp attach_response_metadata(%Effect.LLMDecision{} = decision, model, response) do
    metadata =
      %{}
      |> maybe_put(:usage, response_usage(response))
      |> maybe_put(:model, model_ref(model))
      |> maybe_put(:provider, model_provider(model))
      |> maybe_put(:response_model, response.model)
      |> maybe_put(:finish_reason, ReqLLM.Response.finish_reason(response))
      |> maybe_put(:provider_meta, empty_to_nil(response.provider_meta))
      |> maybe_put(:message_metadata, response_message_metadata(response))

    %Effect.LLMDecision{decision | metadata: Map.merge(decision.metadata, metadata)}
  end

  defp response_content_parts(%ReqLLM.Response{message: nil}), do: {:ok, []}

  defp response_content_parts(%ReqLLM.Response{message: %{content: content}})
       when is_list(content) do
    content
    |> Enum.reject(&(&1.type in [:text, :thinking, :object]))
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, converted} ->
      case from_req_content_part(part) do
        {:ok, converted_part} -> {:cont, {:ok, [converted_part | converted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      error -> error
    end
  end

  defp response_content_parts(%ReqLLM.Response{message: message}),
    do: {:error, {:invalid_provider_message, message}}

  defp from_req_content_part(%LLMContentPart{type: :image_url, url: url} = part) do
    {:ok,
     ContentPart.image({:url, url},
       media_type: media_type(part, "image/*"),
       filename: part.filename,
       metadata: part.metadata
     )}
  end

  defp from_req_content_part(%LLMContentPart{type: :video_url, url: url} = part) do
    {:ok,
     ContentPart.video({:url, url},
       media_type: media_type(part, "video/*"),
       filename: part.filename,
       metadata: part.metadata
     )}
  end

  defp from_req_content_part(%LLMContentPart{type: :image, data: data} = part) do
    {:ok,
     ContentPart.image({:data, data},
       media_type: media_type(part, "image/png"),
       filename: part.filename,
       metadata: part.metadata
     )}
  end

  defp from_req_content_part(%LLMContentPart{type: :file} = part) do
    type = media_content_type(part.media_type)

    with {:ok, source} <- req_file_source(part) do
      opts = [
        media_type: media_type(part, "application/octet-stream"),
        filename: part.filename,
        metadata: part.metadata
      ]

      {:ok, content_part(type, source, opts)}
    end
  end

  defp from_req_content_part(%LLMContentPart{type: type}),
    do: {:error, {:unsupported_provider_content_part, type}}

  defp req_file_source(%LLMContentPart{data: data}) when is_binary(data), do: {:ok, {:data, data}}

  defp req_file_source(%LLMContentPart{file_id: file_id}) when is_binary(file_id),
    do: {:ok, {:file_id, file_id}}

  defp req_file_source(part), do: {:error, {:invalid_provider_file_part, part}}

  defp content_part(:image, source, opts), do: ContentPart.image(source, opts)
  defp content_part(:audio, source, opts), do: ContentPart.audio(source, opts)
  defp content_part(:video, source, opts), do: ContentPart.video(source, opts)
  defp content_part(:document, source, opts), do: ContentPart.document(source, opts)

  defp attach_output_parts(%Effect.LLMDecision{} = decision, []), do: decision

  defp attach_output_parts(%Effect.LLMDecision{type: :final, content: content} = decision, parts) do
    parts = if content == "", do: parts, else: [ContentPart.text(content) | parts]
    %Effect.LLMDecision{decision | parts: parts}
  end

  defp attach_output_parts(%Effect.LLMDecision{} = decision, parts),
    do: %Effect.LLMDecision{decision | parts: parts}

  defp media_type(%LLMContentPart{media_type: media_type}, _default)
       when is_binary(media_type) and media_type != "",
       do: media_type

  defp media_type(%LLMContentPart{metadata: metadata}, default) do
    Map.get(metadata, :media_type, Map.get(metadata, "media_type", default))
  end

  defp media_content_type(media_type) when is_binary(media_type) do
    cond do
      String.starts_with?(media_type, "image/") -> :image
      String.starts_with?(media_type, "audio/") -> :audio
      String.starts_with?(media_type, "video/") -> :video
      true -> :document
    end
  end

  defp media_content_type(_media_type), do: :document

  defp response_message_metadata(%ReqLLM.Response{message: %{metadata: metadata}}),
    do: empty_to_nil(metadata)

  defp response_message_metadata(_response), do: nil

  defp response_usage(response) do
    response
    |> ReqLLM.Response.usage()
    |> Jidoka.Usage.normalize()
    |> empty_to_nil()
  end

  defp model_ref(%LLMDB.Model{} = model), do: LLMDB.Model.spec(model)
  defp model_ref(nil), do: nil

  defp model_provider(%LLMDB.Model{provider: provider}), do: provider
  defp model_provider(nil), do: nil

  defp empty_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_to_nil(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
