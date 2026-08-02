defmodule Jidoka.Adapter.ReqLLM.ResponseAdapter do
  @moduledoc false

  alias Jidoka.ContentPart
  alias Jidoka.Effect
  alias Jidoka.Adapter.ReqLLM.Decision
  alias ReqLLM.Message.ContentPart, as: LLMContentPart

  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(response, model \\ nil)

  def decision(%ReqLLM.Response{} = response, model) do
    decision(response, model, ReqLLM.Response.text(response))
  end

  @spec decision(ReqLLM.Response.t(), LLMDB.Model.t() | nil, String.t() | nil) ::
          {:ok, Effect.LLMDecision.t()} | {:error, term()}
  def decision(%ReqLLM.Response{} = response, model, text) do
    with {:ok, decision} <- Decision.parse_text(text),
         {:ok, parts} <- response_content_parts(response) do
      {:ok,
       decision
       |> attach_output_parts(parts)
       |> attach_response_metadata(model, response)}
    end
  end

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
    |> Enum.reject(&(&1.type in [:text, :thinking]))
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
