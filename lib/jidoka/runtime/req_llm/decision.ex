defmodule Jidoka.Runtime.ReqLLM.Decision do
  @moduledoc """
  Parses the constrained JSON decision protocol used by the ReqLLM runtime.
  """

  alias Jidoka.Effect.LLMDecision
  alias Jidoka.Schema

  @operation_decision_types [
    "operation",
    "tool",
    "tool_call",
    "function",
    "function_call",
    "action"
  ]

  @type t ::
          LLMDecision.t()

  @spec parse_text(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def parse_text(nil), do: {:error, :empty_llm_response}

  def parse_text(text) when is_binary(text) do
    case decode_json_object(text) do
      {:ok, object} -> parse_object(object)
      {:error, _reason} -> {:ok, LLMDecision.final(String.trim(text))}
    end
  end

  @spec parse_object(map()) :: {:ok, t()} | {:error, term()}
  def parse_object(object) when is_map(object) do
    case Schema.get_key(object, :type) do
      "final" ->
        parse_final(object)

      nil ->
        if untyped_operation_shorthand?(object) do
          parse_operation(object)
        else
          parse_untyped_final(object)
        end

      type when type in @operation_decision_types ->
        parse_operation(object)

      type when is_binary(type) ->
        if operation_shorthand?(object) do
          parse_operation(object, type)
        else
          {:error, {:invalid_llm_decision_type, type}}
        end

      type ->
        {:error, {:invalid_llm_decision_type, type}}
    end
  end

  defp parse_final(object) do
    case Schema.get_key(object, :content) do
      content when is_binary(content) ->
        {:ok, LLMDecision.final(content, result: Schema.get_key(object, :result))}

      other ->
        {:error, {:invalid_final_content, other}}
    end
  end

  defp parse_untyped_final(object) when is_map(object) do
    content =
      cond do
        is_binary(Schema.get_key(object, :content)) ->
          Schema.get_key(object, :content)

        is_binary(Schema.get_key(object, :summary)) ->
          Schema.get_key(object, :summary)

        true ->
          Jason.encode!(object)
      end

    {:ok, LLMDecision.final(content, result: Schema.get_key(object, :result) || object)}
  end

  defp parse_operation(object, fallback_name \\ nil) do
    nested = nested_operation_object(object)
    name = operation_name(object, nested, fallback_name)
    arguments = operation_arguments(object, nested, fallback_name)

    build_operation_decision(name, arguments)
  end

  defp operation_name(object, nested, fallback_name) do
    Schema.get_key(object, :name) ||
      Schema.get_key(object, :operation) ||
      Schema.get_key(object, :tool) ||
      Schema.get_key(object, :tool_name) ||
      Schema.get_key(object, :function) ||
      Schema.get_key(object, :function_name) ||
      nested_name(nested) ||
      fallback_name
  end

  defp operation_arguments(object, nested, fallback_name) do
    Schema.get_key(object, :arguments) ||
      Schema.get_key(object, :params) ||
      Schema.get_key(object, :parameters) ||
      Schema.get_key(object, :args) ||
      nested_arguments(nested) ||
      shorthand_arguments(object, fallback_name) ||
      %{}
  end

  defp build_operation_decision(name, arguments) do
    cond do
      not is_binary(name) -> {:error, {:invalid_operation_name, name}}
      not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
      true -> {:ok, LLMDecision.operation(name, arguments)}
    end
  end

  defp operation_shorthand?(object) when is_map(object) do
    match?(%{}, Schema.get_key(object, :arguments)) or
      match?(%{}, Schema.get_key(object, :params)) or
      match?(%{}, Schema.get_key(object, :parameters)) or
      match?(%{}, nested_operation_object(object)) or
      map_size(shorthand_arguments(object, :operation) || %{}) > 0
  end

  defp untyped_operation_shorthand?(object) when is_map(object) do
    is_binary(Schema.get_key(object, :name)) or
      is_binary(Schema.get_key(object, :operation)) or
      is_binary(Schema.get_key(object, :tool)) or
      is_binary(Schema.get_key(object, :tool_name)) or
      is_binary(Schema.get_key(object, :function)) or
      is_binary(Schema.get_key(object, :function_name)) or
      match?(%{}, nested_operation_object(object))
  end

  defp nested_operation_object(object) when is_map(object) do
    cond do
      is_map(Schema.get_key(object, :tool_call)) ->
        Schema.get_key(object, :tool_call)

      is_map(Schema.get_key(object, :tool)) ->
        Schema.get_key(object, :tool)

      is_map(Schema.get_key(object, :function_call)) ->
        Schema.get_key(object, :function_call)

      is_map(Schema.get_key(object, :function)) ->
        Schema.get_key(object, :function)

      is_list(Schema.get_key(object, :tool_calls)) ->
        object
        |> Schema.get_key(:tool_calls)
        |> List.first()

      true ->
        nil
    end
  end

  defp nested_name(%{} = nested) do
    Schema.get_key(nested, :name) ||
      Schema.get_key(nested, :operation) ||
      Schema.get_key(nested, :tool) ||
      Schema.get_key(nested, :tool_name) ||
      Schema.get_key(nested, :function) ||
      Schema.get_key(nested, :function_name)
  end

  defp nested_name(_nested), do: nil

  defp nested_arguments(%{} = nested) do
    Schema.get_key(nested, :arguments) ||
      Schema.get_key(nested, :params) ||
      Schema.get_key(nested, :parameters) ||
      Schema.get_key(nested, :args)
  end

  defp nested_arguments(_nested), do: nil

  defp shorthand_arguments(_object, nil), do: nil

  defp shorthand_arguments(object, _fallback_name) when is_map(object) do
    arguments =
      Map.reject(object, fn {key, _value} ->
        key in [
          :type,
          "type",
          :name,
          "name",
          :operation,
          "operation",
          :content,
          "content",
          :result,
          "result"
        ]
      end)

    if map_size(arguments) > 0, do: arguments, else: nil
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
