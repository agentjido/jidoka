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
  @operations_decision_types [
    "operations",
    "tools",
    "tool_calls",
    "function_calls",
    "actions"
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
    parse_object_by_type(object, Schema.get_key(object, :type))
  end

  defp parse_object_by_type(object, "final"), do: parse_final(object)

  defp parse_object_by_type(object, nil) do
    cond do
      untyped_operations_shorthand?(object) -> parse_operations(object)
      untyped_operation_shorthand?(object) -> parse_operation(object)
      true -> parse_untyped_final(object)
    end
  end

  defp parse_object_by_type(object, type) when type in @operations_decision_types,
    do: parse_operations(object)

  defp parse_object_by_type(object, type) when type in @operation_decision_types do
    if operations_shorthand?(object) do
      parse_operations(object)
    else
      parse_operation(object)
    end
  end

  defp parse_object_by_type(object, type) when is_binary(type) do
    if operation_shorthand?(object) do
      parse_operation(object, type)
    else
      {:error, {:invalid_llm_decision_type, type}}
    end
  end

  defp parse_object_by_type(_object, type), do: {:error, {:invalid_llm_decision_type, type}}

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

  defp parse_operations(object) when is_map(object) do
    object
    |> operation_items()
    |> case do
      operations when is_list(operations) and operations != [] -> parse_operation_items(operations)
      operations -> {:error, {:empty_operations, operations}}
    end
  end

  defp parse_operation_items(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case operation_request(operation) do
        {:ok, request} -> {:cont, {:ok, [request | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, LLMDecision.operations(Enum.reverse(operations))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp operation_items(object) when is_map(object) do
    cond do
      is_list(Schema.get_key(object, :operations)) ->
        Schema.get_key(object, :operations)

      is_list(Schema.get_key(object, :tool_calls)) ->
        Schema.get_key(object, :tool_calls)

      is_list(Schema.get_key(object, :tools)) ->
        Schema.get_key(object, :tools)

      is_list(Schema.get_key(object, :function_calls)) ->
        Schema.get_key(object, :function_calls)

      is_list(Schema.get_key(object, :actions)) ->
        Schema.get_key(object, :actions)

      true ->
        nil
    end
  end

  defp operation_request(%{} = object) do
    nested = nested_operation_object(object)
    name = operation_name(object, nested, nil)
    arguments = operation_arguments(object, nested, nil)

    build_operation_request(name, arguments)
  end

  defp operation_request(other), do: {:error, {:invalid_operation_request, other}}

  defp operation_name(object, nested, fallback_name) do
    candidates = [
      Schema.get_key(object, :name),
      Schema.get_key(object, :operation),
      Schema.get_key(object, :tool),
      Schema.get_key(object, :tool_name),
      Schema.get_key(object, :function),
      Schema.get_key(object, :function_name),
      nested_name(nested),
      fallback_name
    ]

    Enum.find(candidates, &is_binary/1) || Enum.find(candidates, &(not is_nil(&1)))
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
    arguments = normalize_arguments(arguments)

    cond do
      not is_binary(name) -> {:error, {:invalid_operation_name, name}}
      not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
      true -> {:ok, LLMDecision.operation(name, arguments)}
    end
  end

  defp build_operation_request(name, arguments) do
    arguments = normalize_arguments(arguments)

    cond do
      not is_binary(name) -> {:error, {:invalid_operation_name, name}}
      not is_map(arguments) -> {:error, {:invalid_operation_arguments, arguments}}
      true -> {:ok, %{name: name, arguments: arguments}}
    end
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _other -> arguments
    end
  end

  defp normalize_arguments(arguments), do: arguments

  defp operations_shorthand?(object) when is_map(object) do
    is_list(Schema.get_key(object, :operations)) or
      is_list(Schema.get_key(object, :tool_calls)) or
      is_list(Schema.get_key(object, :tools)) or
      is_list(Schema.get_key(object, :function_calls)) or
      is_list(Schema.get_key(object, :actions))
  end

  defp operation_shorthand?(object) when is_map(object) do
    match?(%{}, Schema.get_key(object, :arguments)) or
      match?(%{}, Schema.get_key(object, :params)) or
      match?(%{}, Schema.get_key(object, :parameters)) or
      match?(%{}, nested_operation_object(object)) or
      map_size(shorthand_arguments(object, :operation) || %{}) > 0
  end

  defp untyped_operations_shorthand?(object) when is_map(object) do
    operations_shorthand?(object)
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
