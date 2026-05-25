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

  @type category :: :validation | :configuration | :execution | :internal | :unknown

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

  @doc """
  Returns the public Jidoka error category for an error term.

  The category is intentionally smaller than the internal module hierarchy so
  CLI, Livebook, and UI surfaces can branch on validation, configuration,
  execution, internal, or unknown failures without pattern matching on structs.
  """
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
      |> primary_category()
    else
      :unknown
    end
  end

  def category(_error), do: :unknown

  @doc """
  Returns true when the value is one of Jidoka's normalized error structs.
  """
  @spec normalized?(term()) :: boolean()
  def normalized?(error), do: category(error) != :unknown

  @doc """
  Converts an error into a bounded, display-oriented map.

  This is intended for debugging and user-facing surfaces. It keeps the public
  category and formatted message, and includes sanitized fields/details when the
  error is a normalized Jidoka error.
  """
  @spec to_map(term()) :: map()
  def to_map(%ValidationError{} = error) do
    error
    |> base_error_map()
    |> put_present(:field, error.field)
    |> put_present(:value, sanitized(error.value))
    |> put_present(:details, sanitized(error.details))
  end

  def to_map(%ConfigError{} = error) do
    error
    |> base_error_map()
    |> put_present(:field, error.field)
    |> put_present(:value, sanitized(error.value))
    |> put_present(:details, sanitized(error.details))
  end

  def to_map(%ExecutionError{} = error) do
    error
    |> base_error_map()
    |> put_present(:phase, error.phase)
    |> put_present(:details, sanitized(error.details))
  end

  def to_map(%Internal.UnknownError{} = error) do
    error
    |> base_error_map()
    |> put_present(:details, sanitized(error.details))
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

  def format(%{message: message}) when is_binary(message), do: Jidoka.Sanitize.text(message)
  def format(message) when is_binary(message), do: Jidoka.Sanitize.text(message)
  def format(other), do: other |> Jidoka.Sanitize.payload() |> inspect()

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

  defp primary_category([]), do: :unknown
  defp primary_category([category | _categories]), do: category

  defp base_error_map(error), do: %{category: category(error), message: format(error)}

  defp fallback_error_map(error), do: %{category: :unknown, message: format(error)}

  defp sanitized(nil), do: nil
  defp sanitized(value), do: Jidoka.Sanitize.payload(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
