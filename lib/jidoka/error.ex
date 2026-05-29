defmodule Jidoka.Error do
  @moduledoc """
  Splode-backed error helpers for Jidoka.

  Runtime-facing APIs should return these errors instead of leaking raw atoms,
  tuples, or third-party exception structs. Lower-level constructors may still
  return library-native validation details when that is the precise contract.
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

      defp unknown_message(nil), do: "Unknown Jidoka error"
      defp unknown_message(message) when is_binary(message), do: message
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
  @type context :: keyword() | map()

  @spec validation_error(String.t(), keyword() | map()) :: Exception.t()
  def validation_error(message, details \\ %{}) do
    ValidationError.exception(error_opts(details, message))
  end

  @spec config_error(String.t(), keyword() | map()) :: Exception.t()
  def config_error(message, details \\ %{}) do
    ConfigError.exception(error_opts(details, message))
  end

  @spec execution_error(String.t(), keyword() | map()) :: Exception.t()
  def execution_error(message, details \\ %{}) do
    ExecutionError.exception(error_opts(details, message))
  end

  @doc """
  Normalizes arbitrary error terms into a Jidoka/Splode exception.
  """
  @spec normalize(term(), context()) :: Exception.t()
  def normalize(reason, context \\ %{})

  def normalize(error, context) when is_exception(error) do
    if normalized?(error) do
      error
    else
      execution_error("Jidoka execution failed.",
        phase: detail(context, :phase, :exception),
        details: details(context, %{reason: :exception, cause: error})
      )
    end
  end

  def normalize(reason, context) do
    with :error <- normalize_agent_reason(reason, context),
         :error <- normalize_context_reason(reason, context),
         :error <- normalize_turn_reason(reason, context),
         :error <- normalize_effect_reason(reason, context),
         :error <- normalize_llm_reason(reason, context),
         :error <- normalize_operation_reason(reason, context),
         :error <- normalize_agent_server_reason(reason, context) do
      execution_error(detail(context, :message, "Jidoka execution failed."),
        phase: detail(context, :phase, :runtime),
        details: details(context, %{cause: reason})
      )
    else
      {:ok, error} -> error
    end
  end

  defp normalize_agent_reason(:not_found, context) do
    {:ok,
     validation_error("Jidoka agent could not be found.",
       field: :agent,
       value: detail(context, :target),
       details: details(context, %{reason: :not_found, cause: :not_found})
     )}
  end

  defp normalize_agent_reason(:missing_agent_module, context) do
    {:ok,
     config_error("Jidoka AgentServer context is missing the agent module.",
       field: :agent_module,
       details: details(context, %{reason: :missing_agent_module, cause: :missing_agent_module})
     )}
  end

  defp normalize_agent_reason(_reason, _context), do: :error

  defp normalize_context_reason({:invalid_context, reason}, context) do
    {:ok,
     validation_error("Invalid Jidoka context.",
       field: :context,
       value: detail(context, :context),
       details: details(context, %{reason: :invalid_context, cause: reason})
     )}
  end

  defp normalize_context_reason({:invalid_context_schema, reason}, context) do
    {:ok,
     config_error("Invalid Jidoka context schema.",
       field: :context_schema,
       details: details(context, %{reason: :invalid_context_schema, cause: reason})
     )}
  end

  defp normalize_context_reason(_reason, _context), do: :error

  defp normalize_turn_reason(:missing_input, context) do
    {:ok,
     validation_error("Jidoka turn input is required.",
       field: :input,
       details: details(context, %{reason: :missing_input, cause: :missing_input})
     )}
  end

  defp normalize_turn_reason(:invalid_turn_params, context) do
    {:ok,
     validation_error("Jidoka turn parameters must be a map.",
       field: :params,
       value: detail(context, :value),
       details: details(context, %{reason: :invalid_turn_params, cause: :invalid_turn_params})
     )}
  end

  defp normalize_turn_reason({:max_model_turns_exceeded, max}, context) do
    {:ok,
     execution_error("Maximum model turns exceeded.",
       phase: :turn,
       details:
         details(context, %{reason: :max_model_turns_exceeded, max_model_turns: max, cause: max})
     )}
  end

  defp normalize_turn_reason(_reason, _context), do: :error

  defp normalize_effect_reason(:missing_pending_effect, context) do
    {:ok,
     execution_error("Turn state is missing a pending effect.",
       phase: :effect,
       details:
         details(context, %{reason: :missing_pending_effect, cause: :missing_pending_effect})
     )}
  end

  defp normalize_effect_reason({:missing_pending_effect, _state} = reason, context) do
    {:ok,
     execution_error("Turn state is missing a pending effect.",
       phase: :effect,
       details: details(context, %{reason: :missing_pending_effect, cause: reason})
     )}
  end

  defp normalize_effect_reason({:unsupported_effect_kind, kind} = reason, context) do
    {:ok,
     execution_error("Unsupported effect kind #{inspect(kind)}.",
       phase: :effect,
       details:
         details(context, %{reason: :unsupported_effect_kind, effect_kind: kind, cause: reason})
     )}
  end

  defp normalize_effect_reason({:invalid_capability_result, result} = reason, context) do
    {:ok, invalid_capability_result_error(result, reason, context)}
  end

  defp normalize_effect_reason({:invalid_adapter_result, result} = reason, context) do
    {:ok, invalid_capability_result_error(result, reason, context)}
  end

  defp normalize_effect_reason({:unexpected_effect_result, _state, _result} = reason, context) do
    {:ok,
     execution_error("Unexpected Jidoka effect result.",
       phase: :effect,
       details: details(context, %{reason: :unexpected_effect_result, cause: reason})
     )}
  end

  defp normalize_effect_reason(_reason, _context), do: :error

  defp normalize_llm_reason({:missing_prompt_payload, payload} = reason, context) do
    {:ok,
     execution_error("LLM effect is missing a prompt payload.",
       phase: :llm,
       details:
         details(context, %{reason: :missing_prompt_payload, payload: payload, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_prompt_payload, payload} = reason, context) do
    {:ok,
     execution_error("LLM effect prompt payload is invalid.",
       phase: :llm,
       details:
         details(context, %{reason: :invalid_prompt_payload, payload: payload, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_llm_decision_type, type} = reason, context) do
    {:ok,
     execution_error("LLM returned an unsupported decision type.",
       phase: :llm_decision,
       details:
         details(context, %{
           reason: :invalid_llm_decision_type,
           decision_type: type,
           cause: reason
         })
     )}
  end

  defp normalize_llm_reason({:invalid_final_content, content} = reason, context) do
    {:ok,
     execution_error("LLM final response content must be a string.",
       phase: :llm_decision,
       details:
         details(context, %{reason: :invalid_final_content, content: content, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_operation_name, name} = reason, context) do
    {:ok,
     execution_error("LLM operation name must be a string.",
       phase: :llm_decision,
       details:
         details(context, %{reason: :invalid_operation_name, operation_name: name, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_operation_arguments, arguments} = reason, context) do
    {:ok,
     execution_error("LLM operation arguments must be a map.",
       phase: :llm_decision,
       details:
         details(context, %{
           reason: :invalid_operation_arguments,
           arguments: arguments,
           cause: reason
         })
     )}
  end

  defp normalize_llm_reason(_reason, _context), do: :error

  defp normalize_operation_reason({:unknown_operation, name} = reason, context) do
    {:ok,
     execution_error("LLM requested an operation that is not defined for this agent.",
       phase: :operation,
       details:
         details(context, %{reason: :unknown_operation, operation_name: name, cause: reason})
     )}
  end

  defp normalize_operation_reason(:missing_operations_capability = reason, context) do
    {:ok,
     config_error("Missing Jidoka operations capability.",
       field: :operations,
       details: details(context, %{reason: reason, cause: reason})
     )}
  end

  defp normalize_operation_reason(:missing_operations_adapter = reason, context) do
    {:ok,
     config_error("Missing Jidoka operations capability.",
       field: :operations,
       details:
         details(context, %{
           reason: :missing_operations_capability,
           legacy_reason: :missing_operations_adapter,
           cause: reason
         })
     )}
  end

  defp normalize_operation_reason({:missing_jido_action, name} = reason, context) do
    {:ok,
     execution_error("Jido action tool is not available.",
       phase: :operation,
       details:
         details(context, %{reason: :missing_jido_action, operation_name: name, cause: reason})
     )}
  end

  defp normalize_operation_reason({:missing_operation_handler, name} = reason, context) do
    {:ok,
     execution_error("Operation handler is not available.",
       phase: :operation,
       details:
         details(context, %{
           reason: :missing_operation_handler,
           operation_name: name,
           cause: reason
         })
     )}
  end

  defp normalize_operation_reason({:invalid_operation_handler, handler} = reason, context) do
    {:ok,
     config_error("Operation handler must be a one- or two-arity function.",
       field: :operations,
       value: handler,
       details: details(context, %{reason: :invalid_operation_handler, cause: reason})
     )}
  end

  defp normalize_operation_reason(_reason, _context), do: :error

  defp normalize_agent_server_reason({:unexpected_jidoka_agent_state, _state} = reason, context) do
    {:ok,
     execution_error("Unexpected Jidoka AgentServer state.",
       phase: :agent_server,
       details: details(context, %{reason: :unexpected_jidoka_agent_state, cause: reason})
     )}
  end

  defp normalize_agent_server_reason(_reason, _context), do: :error

  defp invalid_capability_result_error(result, reason, context) do
    execution_error("Runtime capability returned an invalid result.",
      phase: :effect,
      details:
        details(context, %{
          reason: :invalid_capability_result,
          capability_result: result,
          cause: reason
        })
    )
  end

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

  @spec normalized?(term()) :: boolean()
  def normalized?(error), do: category(error) != :unknown

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

  defp error_opts(details, message) when is_map(details) do
    details
    |> Map.put(:message, message)
    |> Map.put_new(:details, %{})
  end

  defp error_opts(details, message) when is_list(details) do
    details
    |> Keyword.put(:message, message)
    |> Keyword.put_new(:details, %{})
  end

  defp details(context, attrs) do
    context
    |> to_context_map()
    |> Map.take([:operation, :phase, :agent_id, :request_id, :target, :intent_id, :effect_kind])
    |> Map.merge(attrs)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp detail(context, key, default \\ nil)
  defp detail(context, key, default) when is_map(context), do: Map.get(context, key, default)
  defp detail(context, key, default) when is_list(context), do: Keyword.get(context, key, default)
  defp detail(_context, _key, default), do: default

  defp to_context_map(context) when is_map(context), do: context
  defp to_context_map(context) when is_list(context), do: Map.new(context)
  defp to_context_map(_context), do: %{}

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
    %{exception: exception.__struct__, message: format(exception)}
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
