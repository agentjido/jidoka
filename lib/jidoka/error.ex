defmodule Jidoka.Error do
  @moduledoc """
  Structured Jidoka error helpers.

  Jidoka uses Splode-backed errors for validation, configuration, and execution
  failures so they can be raised, formatted, and classified consistently.
  """

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Runtime execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      use Splode.Error, class: :internal, fields: [:message, :details, :error]

      @impl true
      def exception(opts) do
        opts = if is_map(opts), do: Map.to_list(opts), else: opts
        message = Keyword.get(opts, :message) || unknown_message(opts[:error])

        opts
        |> Keyword.put(:message, message)
        |> Keyword.put_new(:details, %{})
        |> super()
      end

      defp unknown_message(error) when is_binary(error), do: error
      defp unknown_message(nil), do: "Unknown Jidoka error"
      defp unknown_message(error), do: inspect(error)
    end
  end

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: Internal.UnknownError

  defmodule ValidationError do
    @moduledoc "Invalid input or schema validation error."
    use Splode.Error, class: :invalid, fields: [:message, :field, :value, :details]

    @impl true
    def exception(opts) do
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      opts
      |> Keyword.put_new(:message, "Invalid Jidoka input")
      |> Keyword.put_new(:details, %{})
      |> super()
    end
  end

  defmodule ConfigError do
    @moduledoc "Invalid Jidoka configuration error."
    use Splode.Error, class: :config, fields: [:message, :field, :value, :details]

    @impl true
    def exception(opts) do
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      opts
      |> Keyword.put_new(:message, "Invalid Jidoka configuration")
      |> Keyword.put_new(:details, %{})
      |> super()
    end
  end

  defmodule ExecutionError do
    @moduledoc "Jidoka runtime execution error."
    use Splode.Error, class: :execution, fields: [:message, :phase, :details]

    @impl true
    def exception(opts) do
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      opts
      |> Keyword.put_new(:message, "Jidoka execution failed")
      |> Keyword.put_new(:details, %{})
      |> super()
    end
  end

  @doc """
  Builds a validation error with a consistent Jidoka shape.
  """
  @spec validation_error(String.t(), keyword() | map()) :: Exception.t()
  def validation_error(message, details \\ %{}) do
    ValidationError.exception(put_details(details, message))
  end

  @doc """
  Builds a configuration error with a consistent Jidoka shape.
  """
  @spec config_error(String.t(), keyword() | map()) :: Exception.t()
  def config_error(message, details \\ %{}) do
    ConfigError.exception(put_details(details, message))
  end

  @doc """
  Builds a runtime execution error with a consistent Jidoka shape.
  """
  @spec execution_error(String.t(), keyword() | map()) :: Exception.t()
  def execution_error(message, details \\ %{}) do
    ExecutionError.exception(put_details(details, message))
  end

  @doc """
  Builds an invalid-context validation error.
  """
  @spec invalid_context(term(), keyword() | map()) :: Exception.t()
  def invalid_context(reason, opts \\ %{})

  def invalid_context(:expected_map, opts) do
    validation_error("Invalid context: pass `context:` as a map or keyword list.",
      field: :context,
      value: get_detail(opts, :value),
      details: %{reason: :expected_map}
    )
  end

  def invalid_context({:schema, errors}, opts) do
    validation_error(schema_error_message(errors),
      field: :context,
      value: get_detail(opts, :value),
      details: %{reason: :schema, errors: errors}
    )
  end

  def invalid_context({:schema_result, :expected_map, value}, opts) do
    validation_error("Invalid context schema: expected schema parsing to return a map, got #{inspect(value)}.",
      field: :context,
      value: get_detail(opts, :value),
      details: %{reason: :schema_result, schema_result: value}
    )
  end

  def invalid_context({:domain_mismatch, expected, actual}, opts) do
    validation_error("Invalid context: expected `domain` to be #{inspect(expected)}, got #{inspect(actual)}.",
      field: :domain,
      value: actual,
      details: %{
        reason: :domain_mismatch,
        expected: expected,
        actual: actual,
        context: get_detail(opts, :value)
      }
    )
  end

  @doc """
  Builds an invalid-context-schema configuration error.
  """
  @spec invalid_context_schema(term(), keyword() | map()) :: Exception.t()
  def invalid_context_schema(reason, opts \\ %{})

  def invalid_context_schema(:expected_zoi_schema, opts) do
    config_error("agent context must be a Zoi map/object schema",
      field: :schema,
      value: get_detail(opts, :value),
      details: %{reason: :expected_zoi_schema}
    )
  end

  def invalid_context_schema(:expected_zoi_map_schema, opts) do
    config_error("agent context must be a Zoi map/object schema",
      field: :schema,
      value: get_detail(opts, :value),
      details: %{reason: :expected_zoi_map_schema}
    )
  end

  def invalid_context_schema({:expected_map_result, value}, opts) do
    config_error("agent context must parse context to a map, got: #{inspect(value)}",
      field: :schema,
      value: get_detail(opts, :value),
      details: %{reason: :expected_map_result, schema_result: value}
    )
  end

  @doc """
  Builds an invalid public option error.
  """
  @spec invalid_option(atom(), atom(), keyword() | map()) :: Exception.t()
  def invalid_option(:tool_context, :use_context, opts \\ %{}) do
    validation_error("Invalid option: use `context:` for request-scoped data; `tool_context:` is internal.",
      field: :tool_context,
      value: get_detail(opts, :value),
      details: %{reason: :use_context}
    )
  end

  @doc """
  Builds a missing context validation error.
  """
  @spec missing_context(atom() | String.t(), keyword() | map()) :: Exception.t()
  def missing_context(key, opts \\ %{}) when is_atom(key) or is_binary(key) do
    validation_error("Missing required context key `#{key}`. Pass it with `context: %{#{key}: ...}`.",
      field: key,
      value: get_detail(opts, :value),
      details: %{reason: :missing_context, key: key}
    )
  end

  defp put_details(details, message) when is_map(details) do
    details
    |> Map.put(:message, message)
    |> Map.put_new(:details, %{})
  end

  defp put_details(details, message) when is_list(details) do
    details
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
  end

  @doc """
  Formats Jidoka error terms for humans.
  """
  @spec format(term()) :: String.t()
  def format(%struct{errors: errors} = error) when is_list(errors) do
    if function_exported?(struct, :error_class?, 0) and struct.error_class?() do
      format_error_class(errors)
    else
      inspect(error)
    end
  end

  def format(%{message: message}) when is_binary(message), do: message
  def format(message) when is_binary(message), do: message
  def format(other), do: inspect(other)

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

  defp schema_error_message(errors) do
    case format_schema_errors(errors) do
      "" -> "Invalid context: context did not match the agent context contract."
      formatted -> "Invalid context:\n" <> formatted
    end
  end

  defp format_schema_errors(errors) do
    errors
    |> flatten_schema_errors()
    |> Enum.sort_by(fn {path, message} -> {path, message} end)
    |> Enum.map_join("\n", fn {path, message} -> "- #{path}: #{message}" end)
  end

  defp flatten_schema_errors(errors), do: flatten_schema_errors(errors, [])

  defp flatten_schema_errors(%{} = errors, path) do
    errors
    |> Enum.flat_map(fn {key, value} ->
      flatten_schema_errors(value, path ++ [key])
    end)
  end

  defp flatten_schema_errors(errors, path) when is_list(errors) do
    if Enum.all?(errors, &is_binary/1) do
      Enum.map(errors, fn message -> {format_schema_path(path), message} end)
    else
      Enum.flat_map(errors, &flatten_schema_errors(&1, path))
    end
  end

  defp flatten_schema_errors(error, path) when is_binary(error) do
    [{format_schema_path(path), error}]
  end

  defp flatten_schema_errors(error, path) do
    [{format_schema_path(path), inspect(error)}]
  end

  defp format_schema_path([]), do: "context"

  defp format_schema_path(path) do
    Enum.map_join(path, ".", fn
      key when is_atom(key) -> Atom.to_string(key)
      key when is_binary(key) -> key
      key -> inspect(key)
    end)
  end

  defp get_detail(details, key) when is_map(details), do: Map.get(details, key)
  defp get_detail(details, key) when is_list(details), do: Keyword.get(details, key)
  defp get_detail(_details, _key), do: nil
end
