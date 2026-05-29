defmodule Jidoka.Runtime.ReqLLM.Decision do
  @moduledoc """
  Parses the constrained JSON decision protocol used by the ReqLLM runtime.
  """

  alias Jidoka.Schema

  @type t ::
          %{type: :final, content: String.t()}
          | %{type: :operation, name: String.t(), arguments: map()}

  @spec parse_text(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse_text(nil), do: {:error, :empty_llm_response}

  def parse_text(text) when is_binary(text) do
    case decode_json_object(text) do
      {:ok, object} -> parse_object(object)
      {:error, _reason} -> {:ok, %{type: :final, content: String.trim(text)}}
    end
  end

  @spec parse_object(map()) :: {:ok, t()} | {:error, term()}
  def parse_object(object) when is_map(object) do
    case Schema.get_key(object, :type) do
      "final" ->
        parse_final(object)

      "operation" ->
        parse_operation(object)

      type ->
        {:error, {:invalid_llm_decision_type, type}}
    end
  end

  defp parse_final(object) do
    case Schema.get_key(object, :content) do
      content when is_binary(content) -> {:ok, %{type: :final, content: content}}
      other -> {:error, {:invalid_final_content, other}}
    end
  end

  defp parse_operation(object) do
    name = Schema.get_key(object, :name)
    arguments = Schema.get_key(object, :arguments) || %{}

    cond do
      not is_binary(name) ->
        {:error, {:invalid_operation_name, name}}

      not is_map(arguments) ->
        {:error, {:invalid_operation_arguments, arguments}}

      true ->
        {:ok, %{type: :operation, name: name, arguments: arguments}}
    end
  end

  defp decode_json_object(text) do
    text
    |> trim_markdown_fence()
    |> try_decode_json()
  end

  defp try_decode_json(text) do
    case Jason.decode(text) do
      {:ok, object} when is_map(object) ->
        {:ok, object}

      {:ok, other} ->
        {:error, {:expected_json_object, other}}

      {:error, reason} ->
        text
        |> extract_json_object()
        |> case do
          nil -> {:error, :missing_json_object}
          ^text -> {:error, reason}
          object_text -> try_decode_json(object_text)
        end
    end
  end

  defp trim_markdown_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```\z/, "")
    |> String.trim()
  end

  defp extract_json_object(text) do
    with {start, 1} <- :binary.match(text, "{"),
         {finish, 1} <- text |> String.reverse() |> :binary.match("}") do
      last_index = byte_size(text) - finish - 1
      binary_part(text, start, last_index - start + 1)
    else
      _ -> nil
    end
  end
end
