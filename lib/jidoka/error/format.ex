defmodule Jidoka.Error.Format do
  @moduledoc false

  alias Jidoka.Error.{Config, ConfigError, Execution, ExecutionError, Internal, Invalid, ValidationError}

  @type category :: :validation | :configuration | :execution | :internal | :unknown

  @max_depth 8
  @max_collection_entries 50
  @max_string_characters 4_096
  @max_binary_bytes 4_096
  @max_integer_digits 256
  @truncation_key "__jidoka_truncated__"

  @spec category(term()) :: category()
  def category(%ValidationError{}), do: :validation
  def category(%Invalid{}), do: :validation
  def category(%ConfigError{}), do: :configuration
  def category(%Config{}), do: :configuration
  def category(%ExecutionError{}), do: :execution
  def category(%Execution{}), do: :execution
  def category(%Internal.UnknownError{}), do: :internal
  def category(%Internal{}), do: :internal

  def category(%struct{errors: errors}) when is_list(errors) do
    if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
      errors
      |> flatten_class_errors()
      |> Enum.map(&category/1)
      |> Enum.reject(&(&1 == :unknown))
      |> case do
        [] -> :unknown
        [category | _] -> category
      end
    else
      :unknown
    end
  end

  def category(_error), do: :unknown

  @spec to_map(term()) :: map()
  def to_map(%ValidationError{} = error) do
    error
    |> base_error_map()
    |> put_present(:field, error.field)
    |> put_present(:value, sanitize_payload(error.value))
    |> put_present(:details, sanitize_payload(error.details))
  end

  def to_map(%ConfigError{} = error) do
    error
    |> base_error_map()
    |> put_present(:field, error.field)
    |> put_present(:value, sanitize_payload(error.value))
    |> put_present(:details, sanitize_payload(error.details))
  end

  def to_map(%ExecutionError{} = error) do
    error
    |> base_error_map()
    |> put_present(:phase, error.phase)
    |> put_present(:details, sanitize_payload(error.details))
  end

  def to_map(%Internal.UnknownError{} = error) do
    error
    |> base_error_map()
    |> put_present(:details, sanitize_payload(error.details))
  end

  def to_map(%struct{errors: errors} = error) when is_list(errors) do
    if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
      error
      |> base_error_map()
      |> Map.put(:errors, Enum.map(flatten_class_errors(errors), &to_map/1))
    else
      fallback_error_map(error)
    end
  end

  def to_map(error), do: fallback_error_map(error)

  @spec format(term()) :: String.t()
  def format(%struct{errors: errors} = error) when is_list(errors) do
    if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
      format_error_class(errors)
    else
      inspect(sanitize_payload(error))
    end
  end

  def format(%{message: message}) when is_binary(message), do: sanitize_text(message)
  def format(message) when is_binary(message), do: sanitize_text(message)
  def format(other), do: other |> sanitize_payload() |> inspect()

  defp base_error_map(error), do: %{category: category(error), message: format(error)}
  defp fallback_error_map(error), do: %{category: :unknown, message: format(error)}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp format_error_class(errors) do
    errors
    |> flatten_class_errors()
    |> Enum.map(&format/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> "Jidoka operation failed."
      [message] -> message
      messages -> "Multiple Jidoka errors:\n" <> Enum.map_join(messages, "\n", &"- #{&1}")
    end
  end

  defp flatten_class_errors(errors) do
    errors
    |> List.wrap()
    |> Enum.flat_map(fn
      %struct{errors: nested} = error when is_list(nested) ->
        if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
          flatten_class_errors(nested)
        else
          [error]
        end

      error ->
        [error]
    end)
  end

  @secret_key_patterns [:api_key, :authorization, :password, :secret, :token]
  @omitted_key_patterns [:messages, :prompt, :raw_response, :request_body, :response_body]

  defp sanitize_payload(value), do: sanitize_payload(value, 0)

  defp sanitize_payload(_value, depth) when depth >= @max_depth,
    do: %{@truncation_key => "depth"}

  defp sanitize_payload(%_{} = exception, depth) when is_exception(exception) do
    %{
      exception: exception.__struct__,
      message: sanitize_payload(Exception.message(exception), depth + 1)
    }
  end

  defp sanitize_payload(%_{} = struct, depth),
    do: struct |> Map.from_struct() |> sanitize_payload(depth)

  defp sanitize_payload(%{} = map, depth) do
    entries = Enum.take(map, @max_collection_entries + 1)
    {retained, overflow} = Enum.split(entries, @max_collection_entries)

    projected =
      Map.new(retained, fn {key, value} ->
        key = sanitize_key(key)

        cond do
          sensitive_key?(key) -> {key, "[REDACTED]"}
          omitted_key?(key) -> {key, "[OMITTED]"}
          true -> {key, sanitize_payload(value, depth + 1)}
        end
      end)

    if overflow == [],
      do: projected,
      else: Map.put(projected, @truncation_key, "collection")
  end

  defp sanitize_payload(list, depth) when is_list(list),
    do: sanitize_list(list, depth + 1, @max_collection_entries, [])

  defp sanitize_payload(tuple, depth) when is_tuple(tuple) do
    values =
      tuple
      |> Tuple.to_list()
      |> sanitize_payload(depth + 1)

    %{type: "tuple", values: values}
  end

  defp sanitize_payload(value, _depth) when is_pid(value), do: %{type: "pid"}
  defp sanitize_payload(value, _depth) when is_reference(value), do: %{type: "reference"}
  defp sanitize_payload(value, _depth) when is_port(value), do: %{type: "port"}

  defp sanitize_payload(value, _depth) when is_function(value) do
    {:arity, arity} = :erlang.fun_info(value, :arity)
    %{type: "function", arity: arity}
  end

  defp sanitize_payload(value, _depth) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        retained = binary_part(value, 0, min(byte_size(value), @max_binary_bytes))

        %{
          @truncation_key => if(byte_size(value) > @max_binary_bytes, do: "binary", else: nil),
          type: "binary",
          encoding: "base64",
          data: Base.encode64(retained)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      String.length(value) > @max_string_characters ->
        %{
          @truncation_key => "string",
          value: value |> String.slice(0, @max_string_characters) |> sanitize_text()
        }

      true ->
        sanitize_text(value)
    end
  end

  defp sanitize_payload(value, _depth) when is_integer(value) do
    encoded = Integer.to_string(value)

    if byte_size(encoded) > @max_integer_digits do
      %{
        @truncation_key => "integer",
        type: "integer",
        value: binary_part(encoded, 0, @max_integer_digits)
      }
    else
      value
    end
  end

  defp sanitize_payload(value, _depth)
       when is_atom(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize_payload(value, _depth), do: %{type: "term", value: inspect(value, limit: 10, printable_limit: 200)}

  defp sanitize_list([], _depth, _remaining, retained), do: Enum.reverse(retained)

  defp sanitize_list([head | tail], depth, remaining, retained) when remaining > 0 do
    sanitize_list(tail, depth, remaining - 1, [sanitize_payload(head, depth) | retained])
  end

  defp sanitize_list([_head | _tail], _depth, 0, retained),
    do: Enum.reverse([%{@truncation_key => "collection"} | retained])

  defp sanitize_list(improper_tail, depth, _remaining, retained) do
    marker = %{type: "improper_list_tail", value: sanitize_payload(improper_tail, depth)}
    Enum.reverse([marker | retained])
  end

  defp sanitize_key(key) when is_atom(key) or is_integer(key), do: key

  defp sanitize_key(key) when is_binary(key) do
    cond do
      not String.valid?(key) -> "binary-key:" <> Base.encode64(binary_part(key, 0, min(byte_size(key), 128)))
      String.length(key) > 256 -> String.slice(key, 0, 256) <> "[TRUNCATED]"
      true -> key
    end
  end

  defp sanitize_key(key), do: inspect(sanitize_payload(key), limit: 10, printable_limit: 200)

  defp sensitive_key?(key), do: key_matches?(key, @secret_key_patterns)
  defp omitted_key?(key), do: key_matches?(key, @omitted_key_patterns)

  defp key_matches?(key, patterns) when is_atom(key) or is_binary(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(patterns, &String.contains?(key, Atom.to_string(&1)))
  end

  defp key_matches?(_key, _patterns), do: false

  defp sanitize_text(text) do
    text
    |> then(&Regex.replace(~r/sk-[a-zA-Z0-9_-]{8,}/, &1, "[REDACTED]"))
    |> then(&Regex.replace(~r/token=[a-zA-Z0-9_-]+/, &1, "token=[REDACTED]"))
  end
end
