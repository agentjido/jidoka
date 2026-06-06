defmodule Jidoka.Error.Normalize.Basic do
  @moduledoc false

  import Jidoka.Error.Normalize.Helpers

  alias Jidoka.Effect

  @spec normalize(term(), keyword() | map()) :: {:ok, Exception.t()} | :error
  def normalize(reason, context) do
    with :error <- normalize_agent_reason(reason, context),
         :error <- normalize_context_reason(reason, context),
         :error <- normalize_turn_reason(reason, context),
         :error <- normalize_effect_reason(reason, context),
         :error <- normalize_control_reason(reason, context) do
      :error
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
       details: details(context, %{reason: :max_model_turns_exceeded, max_model_turns: max, cause: max})
     )}
  end

  defp normalize_turn_reason({:turn_timeout_exceeded, timeout_ms, elapsed_ms} = reason, context) do
    {:ok,
     execution_error("Jidoka turn timed out.",
       phase: :turn,
       details:
         details(context, %{
           reason: :turn_timeout_exceeded,
           timeout_ms: timeout_ms,
           elapsed_ms: elapsed_ms,
           cause: reason
         })
     )}
  end

  defp normalize_turn_reason(_reason, _context), do: :error

  defp normalize_effect_reason(:missing_pending_effect, context) do
    {:ok,
     execution_error("Turn state is missing a pending effect.",
       phase: :effect,
       details: details(context, %{reason: :missing_pending_effect, cause: :missing_pending_effect})
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
       details: details(context, %{reason: :unsupported_effect_kind, effect_kind: kind, cause: reason})
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

  defp normalize_effect_reason(
         {:unsafe_once_incomplete_effect, %Effect.Intent{} = intent} = reason,
         context
       ) do
    {:ok,
     execution_error("Unsafe operation effect is incomplete and cannot be retried automatically.",
       phase: :effect,
       details:
         details(context, %{
           reason: :unsafe_once_incomplete_effect,
           operation_name: effect_operation_name(intent),
           intent_id: intent.id,
           idempotency: intent.idempotency,
           idempotency_key: intent.idempotency_key,
           cause: reason
         })
     )}
  end

  defp normalize_effect_reason(_reason, _context), do: :error

  defp normalize_control_reason({:control_blocked, control, boundary, cause}, context) do
    {:ok,
     execution_error("Jidoka control blocked the turn.",
       phase: :control,
       details:
         details(context, %{reason: :control_blocked, control: control_name(control), boundary: boundary, cause: cause})
     )}
  end

  defp normalize_control_reason({:control_interrupted, control, boundary, cause}, context) do
    {:ok,
     execution_error("Jidoka control interrupted the turn.",
       phase: :control,
       details:
         details(context, %{
           reason: :control_interrupted,
           control: control_name(control),
           boundary: boundary,
           cause: cause
         })
     )}
  end

  defp normalize_control_reason({:control_failed, control, boundary, cause}, context) do
    {:ok,
     execution_error("Jidoka control failed.",
       phase: :control,
       details:
         details(context, %{reason: :control_failed, control: control_name(control), boundary: boundary, cause: cause})
     )}
  end

  defp normalize_control_reason({:invalid_control_decision, control, boundary, decision}, context) do
    {:ok,
     execution_error("Jidoka control returned an invalid decision.",
       phase: :control,
       details:
         details(context, %{
           reason: :invalid_control_decision,
           control: control_name(control),
           boundary: boundary,
           decision: decision
         })
     )}
  end

  defp normalize_control_reason(_reason, _context), do: :error

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
end
