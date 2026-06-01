defmodule Jidoka.ErrorTest.Support.NonSplodeClass do
  defstruct [:errors, :message]
end

defmodule Jidoka.ErrorTest do
  use ExUnit.Case, async: true

  alias Jidoka.Error
  alias Jidoka.ErrorTest.Support.NonSplodeClass

  test "constructs categorized Splode errors" do
    validation = Error.validation_error("Missing input", field: :input)
    config = Error.config_error("Bad config", field: :model)
    execution = Error.execution_error("Tool failed", phase: :effect)

    assert %Error.ValidationError{} = validation
    assert %Error.ConfigError{} = config
    assert %Error.ExecutionError{} = execution

    assert Error.category(validation) == :validation
    assert Error.category(config) == :configuration
    assert Error.category(execution) == :execution

    assert Error.normalized?(validation)
    refute Error.normalized?(:boom)
  end

  test "normalizes common runtime reasons" do
    assert %Error.ValidationError{field: :input, details: %{reason: :missing_input}} =
             Error.normalize(:missing_input)

    assert %Error.ConfigError{
             field: :operations,
             details: %{reason: :missing_operations_capability}
           } = Error.normalize(:missing_operations_capability)

    assert %Error.ExecutionError{
             phase: :operation,
             details: %{reason: :missing_operation_handler, operation_name: "weather"}
           } = Error.normalize({:missing_operation_handler, "weather"})

    normalized = Error.validation_error("Already normalized")
    assert Error.normalize(normalized) == normalized
  end

  test "normalizes known validation and configuration reasons" do
    assert %Error.ValidationError{
             field: :agent,
             value: "agent-1",
             details: %{reason: :not_found, target: "agent-1"}
           } = Error.normalize(:not_found, target: "agent-1")

    assert %Error.ConfigError{
             field: :agent_module,
             details: %{reason: :missing_agent_module}
           } = Error.normalize(:missing_agent_module)

    assert %Error.ValidationError{field: :params, value: nil} =
             Error.normalize(:invalid_turn_params, :not_context)

    assert %Error.ConfigError{field: :context_schema, details: %{reason: :invalid_context_schema}} =
             Error.normalize({:invalid_context_schema, %RuntimeError{message: "bad schema"}})

    assert %Error.ConfigError{
             field: :operations,
             value: :not_a_function,
             details: %{reason: :invalid_operation_handler}
           } = Error.normalize({:invalid_operation_handler, :not_a_function})
  end

  test "normalizes known execution reasons" do
    cases = [
      {{:max_model_turns_exceeded, 3}, :turn, :max_model_turns_exceeded},
      {{:turn_timeout_exceeded, 1_000, 1_001}, :turn, :turn_timeout_exceeded},
      {{:missing_pending_effect, %{}}, :effect, :missing_pending_effect},
      {{:unsupported_effect_kind, :stream}, :effect, :unsupported_effect_kind},
      {{:invalid_capability_result, :ok}, :effect, :invalid_capability_result},
      {{:control_blocked, Jidoka.ErrorTest.Support.NonSplodeClass, :input, :nope}, :control, :control_blocked},
      {{:invalid_control_decision, Jidoka.ErrorTest.Support.NonSplodeClass, :input, :wat}, :control,
       :invalid_control_decision},
      {{:missing_prompt_payload, %{}}, :llm, :missing_prompt_payload},
      {{:invalid_prompt_payload, "bad"}, :llm, :invalid_prompt_payload},
      {{:invalid_llm_decision_type, "bad"}, :llm_decision, :invalid_llm_decision_type},
      {{:invalid_final_content, 123}, :llm_decision, :invalid_final_content},
      {{:invalid_operation_name, nil}, :llm_decision, :invalid_operation_name},
      {{:invalid_operation_arguments, "bad"}, :llm_decision, :invalid_operation_arguments},
      {{:unknown_operation, "weather"}, :operation, :unknown_operation},
      {{:missing_jido_action, "weather"}, :operation, :missing_jido_action},
      {{:unexpected_effect_result, %{}, %{}}, :effect, :unexpected_effect_result},
      {{:unexpected_jidoka_agent_state, %{}}, :agent_server, :unexpected_jidoka_agent_state}
    ]

    for {reason, phase, normalized_reason} <- cases do
      assert %Error.ExecutionError{
               phase: ^phase,
               details: %{reason: ^normalized_reason, request_id: "request-1"}
             } = Error.normalize(reason, request_id: "request-1")
    end
  end

  test "normalizes legacy adapter reasons to capability errors" do
    assert %Error.ConfigError{
             field: :operations,
             details: %{
               reason: :missing_operations_capability,
               legacy_reason: :missing_operations_adapter
             }
           } = Error.normalize(:missing_operations_adapter)

    assert %Error.ExecutionError{
             phase: :effect,
             details: %{
               reason: :invalid_capability_result,
               capability_result: :ok,
               cause: {:invalid_adapter_result, :ok}
             }
           } = Error.normalize({:invalid_adapter_result, :ok})
  end

  test "wraps exceptions with execution context" do
    error = Error.normalize(%RuntimeError{message: "boom"}, operation: :run_turn, phase: :effect)

    assert %Error.ExecutionError{
             phase: :effect,
             details: %{operation: :run_turn, reason: :exception, cause: %RuntimeError{}}
           } = error
  end

  test "formats and maps sanitized errors" do
    error =
      Error.validation_error("Rejected sk-testsecret123",
        field: :api_key,
        value: "sk-testsecret123",
        details: %{
          api_key: "sk-testsecret123",
          messages: [%{role: :user, content: "hide me"}],
          nested: %{token: "token=abc123"}
        }
      )

    assert Error.format(error) == "Rejected [REDACTED]"

    assert %{
             category: :validation,
             message: "Rejected [REDACTED]",
             field: :api_key,
             value: "[REDACTED]",
             details: %{
               api_key: "[REDACTED]",
               messages: "[OMITTED]",
               nested: %{token: "[REDACTED]"}
             }
           } = Error.to_map(error)
  end

  test "maps config, execution, and fallback errors" do
    config = Error.config_error("Bad model", field: :model, value: %{api_key: "sk-testsecret123"})
    execution = Error.execution_error("Tool failed", phase: :effect, details: %{cause: :boom})
    wrapped_exception = Error.normalize(%RuntimeError{message: "boom"}, phase: :effect)

    assert %{
             category: :configuration,
             field: :model,
             value: %{api_key: "[REDACTED]"}
           } = Error.to_map(config)

    assert %{category: :execution, phase: :effect, details: %{cause: :boom}} =
             Error.to_map(execution)

    assert %{details: %{cause: %{exception: RuntimeError, message: "boom"}}} =
             Error.to_map(wrapped_exception)

    assert %{category: :unknown, message: ":boom"} = Error.to_map(:boom)
  end

  test "formats Splode error classes" do
    error_class =
      Error.to_class([
        Error.validation_error("Missing input", field: :input),
        Error.execution_error("Tool failed", phase: :effect)
      ])

    assert Error.category(error_class) == :validation
    assert Error.format(error_class) == "Multiple Jidoka errors:\n- Missing input\n- Tool failed"

    assert %{category: :validation, errors: errors} = Error.to_map(error_class)
    assert length(errors) == 2
  end

  test "handles Splode class modules and unknown errors" do
    config_class = Error.Config.exception(errors: [Error.config_error("Bad config")])
    execution_class = Error.Execution.exception(errors: [Error.execution_error("Boom")])
    unknown = Error.Internal.UnknownError.exception(error: nil)
    internal_class = Error.Internal.exception(errors: [unknown])

    assert Error.category(config_class) == :configuration
    assert Error.category(execution_class) == :execution
    assert Error.category(unknown) == :internal
    assert Error.category(internal_class) == :internal

    assert Error.to_map(unknown).message == "Unknown Jidoka error"
    assert Error.format(Error.Internal.exception(errors: [])) == "Jidoka operation failed."

    assert Error.format(Error.Invalid.exception(errors: [Error.validation_error("Only one")])) ==
             "Only one"
  end

  test "falls back for non-Jidoka values and non-Splode error-shaped structs" do
    non_splode = %NonSplodeClass{errors: [], message: "not splode"}

    assert Error.category(non_splode) == :unknown
    assert Error.to_map(non_splode).category == :unknown
    assert Error.format(non_splode) =~ "not splode"
    assert Error.format("token=abc123") == "token=[REDACTED]"

    assert %Error.ExecutionError{details: %{cause: {:throw, :halt}, request_id: "request-2"}} =
             Error.normalize({:throw, :halt}, request_id: "request-2")
  end
end
