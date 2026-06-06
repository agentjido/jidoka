defmodule Jidoka.Error.Normalize.Runtime do
  @moduledoc false

  import Jidoka.Error.Normalize.Helpers

  @spec normalize(term(), keyword() | map()) :: {:ok, Exception.t()} | :error
  def normalize(reason, context) do
    with :error <- normalize_approval_reason(reason, context),
         :error <- normalize_result_reason(reason, context),
         :error <- normalize_llm_reason(reason, context),
         :error <- normalize_operation_reason(reason, context),
         :error <- normalize_agent_server_reason(reason, context) do
      :error
    end
  end

  defp normalize_approval_reason({:invalid_approval_response, cause}, context) do
    {:ok,
     validation_error("Approval response is invalid.",
       field: :approval,
       details: details(context, %{reason: :invalid_approval_response, cause: cause})
     )}
  end

  defp normalize_approval_reason({:invalid_approval_ttl_ms, value} = reason, context) do
    {:ok,
     validation_error("Approval TTL must be a positive integer in milliseconds.",
       field: :approval_ttl_ms,
       value: value,
       details: details(context, %{reason: :invalid_approval_ttl_ms, cause: reason})
     )}
  end

  defp normalize_approval_reason({:approval_interrupt_mismatch, expected, actual} = reason, context) do
    {:ok,
     execution_error("Approval response targets a different interrupt.",
       phase: :approval,
       details:
         details(context, %{
           reason: :approval_interrupt_mismatch,
           expected_interrupt_id: expected,
           actual_interrupt_id: actual,
           cause: reason
         })
     )}
  end

  defp normalize_approval_reason({:approval_expired, interrupt_id, responded_at_ms, expires_at_ms} = reason, context) do
    {:ok,
     execution_error("Approval response expired.",
       phase: :approval,
       details:
         details(context, %{
           reason: :approval_expired,
           interrupt_id: interrupt_id,
           responded_at_ms: responded_at_ms,
           expires_at_ms: expires_at_ms,
           cause: reason
         })
     )}
  end

  defp normalize_approval_reason({:approval_denied, response} = reason, context) do
    {:ok,
     execution_error("Approval response denied the pending operation.",
       phase: :approval,
       details:
         details(context, %{
           reason: :approval_denied,
           interrupt_id: Map.get(response, :interrupt_id),
           decision: Map.get(response, :decision),
           approval_reason: Map.get(response, :reason),
           cause: reason
         })
     )}
  end

  defp normalize_approval_reason({:approval_effect_mismatch, expected, actual} = reason, context) do
    {:ok,
     execution_error("Approval response does not match the pending effect.",
       phase: :approval,
       details:
         details(context, %{
           reason: :approval_effect_mismatch,
           expected_effect_id: expected,
           actual_effect_id: actual,
           cause: reason
         })
     )}
  end

  defp normalize_approval_reason(_reason, _context), do: :error

  defp normalize_result_reason({:invalid_result, cause}, context) do
    {:ok,
     execution_error("LLM final result does not match the declared result schema.",
       phase: :result,
       details: details(context, %{reason: :invalid_result, cause: cause})
     )}
  end

  defp normalize_result_reason({:invalid_result, cause, attempts, max_repairs}, context) do
    {:ok,
     execution_error("LLM final result does not match the declared result schema.",
       phase: :result,
       details:
         details(context, %{
           reason: :invalid_result,
           repair_attempts: attempts,
           max_repairs: max_repairs,
           cause: cause
         })
     )}
  end

  defp normalize_result_reason(_reason, _context), do: :error

  defp normalize_llm_reason({:missing_prompt_payload, payload} = reason, context) do
    {:ok,
     execution_error("LLM effect is missing a prompt payload.",
       phase: :llm,
       details: details(context, %{reason: :missing_prompt_payload, payload: payload, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_prompt_payload, payload} = reason, context) do
    {:ok,
     execution_error("LLM effect prompt payload is invalid.",
       phase: :llm,
       details: details(context, %{reason: :invalid_prompt_payload, payload: payload, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_llm_decision_type, type} = reason, context) do
    {:ok,
     execution_error("LLM returned an unsupported decision type.",
       phase: :llm_decision,
       details: details(context, %{reason: :invalid_llm_decision_type, decision_type: type, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_final_content, content} = reason, context) do
    {:ok,
     execution_error("LLM final response content must be a string.",
       phase: :llm_decision,
       details: details(context, %{reason: :invalid_final_content, content: content, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_operation_name, name} = reason, context) do
    {:ok,
     execution_error("LLM operation name must be a string.",
       phase: :llm_decision,
       details: details(context, %{reason: :invalid_operation_name, operation_name: name, cause: reason})
     )}
  end

  defp normalize_llm_reason({:invalid_operation_arguments, arguments} = reason, context) do
    {:ok,
     execution_error("LLM operation arguments must be a map.",
       phase: :llm_decision,
       details: details(context, %{reason: :invalid_operation_arguments, arguments: arguments, cause: reason})
     )}
  end

  defp normalize_llm_reason(_reason, _context), do: :error

  defp normalize_operation_reason({:unknown_operation, name} = reason, context) do
    {:ok,
     execution_error("LLM requested an operation that is not defined for this agent.",
       phase: :operation,
       details: details(context, %{reason: :unknown_operation, operation_name: name, cause: reason})
     )}
  end

  defp normalize_operation_reason({:unsafe_once_requires_control, name, kind} = reason, context) do
    {:ok,
     config_error("Unsafe operation requires an explicit operation control.",
       field: :controls,
       details:
         details(context, %{
           reason: :unsafe_once_requires_control,
           operation_name: name,
           operation_kind: kind,
           idempotency: :unsafe_once,
           cause: reason
         })
     )}
  end

  defp normalize_operation_reason({:duplicate_operation_source_name, name} = reason, context) do
    {:ok,
     config_error("Operation source names must be unique.",
       field: :operations,
       details: details(context, %{reason: :duplicate_operation_source_name, operation_name: name, cause: reason})
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
       details: details(context, %{reason: :missing_jido_action, operation_name: name, cause: reason})
     )}
  end

  defp normalize_operation_reason({:missing_operation_handler, name} = reason, context) do
    {:ok,
     execution_error("Operation handler is not available.",
       phase: :operation,
       details: details(context, %{reason: :missing_operation_handler, operation_name: name, cause: reason})
     )}
  end

  defp normalize_operation_reason({:invalid_operation_handler, handler} = reason, context) do
    {:ok,
     config_error("Operation handler must be a two- or three-arity function.",
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
end
