defmodule Jidoka.Error.Format do
  @moduledoc false

  alias Jidoka.Error.{Config, ConfigError, Execution, ExecutionError, Internal, Invalid, ValidationError}

  @type category :: :validation | :configuration | :execution | :internal | :unknown

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

  defp sanitize_payload(%_{} = exception) when is_exception(exception) do
    %{exception: exception.__struct__, message: sanitize_text(Exception.message(exception))}
  end

  defp sanitize_payload(%_{} = struct), do: struct |> Map.from_struct() |> sanitize_payload()

  defp sanitize_payload(%{} = map) do
    Map.new(map, fn {key, value} ->
      cond do
        sensitive_key?(key) -> {key, "[REDACTED]"}
        omitted_key?(key) -> {key, "[OMITTED]"}
        true -> {key, sanitize_payload(value)}
      end
    end)
  end

  defp sanitize_payload(list) when is_list(list), do: Enum.map(list, &sanitize_payload/1)
  defp sanitize_payload(value) when is_binary(value), do: sanitize_text(value)
  defp sanitize_payload(value), do: value

  defp sensitive_key?(key), do: key_matches?(key, @secret_key_patterns)
  defp omitted_key?(key), do: key_matches?(key, @omitted_key_patterns)

  defp key_matches?(key, patterns) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(patterns, &String.contains?(key, Atom.to_string(&1)))
  end

  defp sanitize_text(text) do
    text
    |> then(&Regex.replace(~r/sk-[a-zA-Z0-9_-]{8,}/, &1, "[REDACTED]"))
    |> then(&Regex.replace(~r/token=[a-zA-Z0-9_-]+/, &1, "token=[REDACTED]"))
  end
end
