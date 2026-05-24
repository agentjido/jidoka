defmodule Jidoka.Error.Normalize do
  @moduledoc false

  alias Jidoka.Error

  import Jidoka.Error.Normalize.Common,
    only: [
      execution: 4,
      execution: 5,
      memory_exception_error: 3,
      passthrough_or_execution: 4,
      passthrough_or_validation: 4,
      timeout_error: 3,
      validation: 4
    ]

  import Jidoka.Error.Normalize.Context,
    only: [
      detail: 2,
      detail: 3,
      details: 2,
      jidoka_error?: 1,
      to_map: 1
    ]

  @type context :: keyword() | map()

  @spec chat_error(term(), context()) :: Exception.t() | {:handoff, Jidoka.Handoff.t()}
  def chat_error(reason, context \\ %{})

  def chat_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "Jidoka chat failed.", :chat, context)

  def chat_error(:not_found, context) do
    Error.validation_error("Jidoka agent could not be found. Start it first, or pass a compiled agent module/session.",
      field: :agent,
      value: detail(context, :target),
      details: details(context, %{operation: :chat, reason: :not_found, cause: :not_found})
    )
  end

  def chat_error({:hook, stage, reason}, context), do: hook_error(stage, reason, context)
  def chat_error({:guardrail, stage, label, reason}, context), do: guardrail_error(stage, label, reason, context)
  def chat_error({:memory, reason}, context), do: memory_error(:retrieve, reason, context)
  def chat_error({:handoff, %Jidoka.Handoff{} = handoff}, _context), do: {:handoff, handoff}
  def chat_error({:timeout, timeout}, context), do: timeout_error(:chat, timeout, context)
  def chat_error(:timeout, context), do: timeout_error(:chat, detail(context, :timeout), context)

  def chat_error({:failed, _status, reason}, context), do: chat_error(reason, context)

  def chat_error(reason, context) do
    Error.execution_error("Jidoka chat failed.",
      phase: :chat,
      details: details(context, %{operation: :chat, cause: reason})
    )
  end

  @spec chat_option_error(term(), context()) :: Exception.t()
  def chat_option_error(reason, context \\ %{})

  def chat_option_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_validation(error, "Invalid chat options.", :chat_options, context)

  def chat_option_error({:invalid_hook_spec, message}, context) when is_binary(message) do
    Error.validation_error(message,
      field: :hooks,
      value: detail(context, :value),
      details: details(context, %{operation: :prepare_chat_opts, reason: :invalid_hook_spec, cause: message})
    )
  end

  def chat_option_error({:invalid_guardrail_spec, message}, context) when is_binary(message) do
    chat_option_error({:invalid_control_spec, message}, context)
  end

  def chat_option_error({:invalid_control_spec, message}, context) when is_binary(message) do
    Error.validation_error(message,
      field: :controls,
      value: detail(context, :value),
      details: details(context, %{operation: :prepare_chat_opts, reason: :invalid_control_spec, cause: message})
    )
  end

  def chat_option_error({:invalid_hook_stage, stage}, context) do
    Error.validation_error("Invalid hook stage #{inspect(stage)}.",
      field: :hooks,
      value: stage,
      details:
        details(context, %{operation: :prepare_chat_opts, reason: :invalid_hook_stage, stage: stage, cause: stage})
    )
  end

  def chat_option_error({:invalid_guardrail_stage, stage}, context) do
    chat_option_error({:invalid_control_stage, stage}, context)
  end

  def chat_option_error({:invalid_control_stage, stage}, context) do
    Error.validation_error("Invalid control stage #{inspect(stage)}.",
      field: :controls,
      value: stage,
      details:
        details(context, %{
          operation: :prepare_chat_opts,
          reason: :invalid_control_stage,
          stage: stage,
          cause: stage
        })
    )
  end

  def chat_option_error({:invalid_hook, stage, message}, context) when is_binary(message) do
    Error.validation_error(message,
      field: :hooks,
      value: stage,
      details: details(context, %{operation: :prepare_chat_opts, reason: :invalid_hook, stage: stage, cause: message})
    )
  end

  def chat_option_error({:invalid_guardrail, stage, message}, context) when is_binary(message) do
    chat_option_error({:invalid_control, stage, message}, context)
  end

  def chat_option_error({:invalid_control, stage, message}, context) when is_binary(message) do
    Error.validation_error(message,
      field: :controls,
      value: stage,
      details:
        details(context, %{operation: :prepare_chat_opts, reason: :invalid_control, stage: stage, cause: message})
    )
  end

  def chat_option_error({:invalid_character, message}, context) when is_binary(message) do
    Error.validation_error(message,
      field: :character,
      value: detail(context, :value),
      details: details(context, %{operation: :prepare_chat_opts, reason: :invalid_character, cause: message})
    )
  end

  def chat_option_error({:invalid_conversation, value}, context) do
    Error.validation_error("Invalid conversation: pass `conversation:` as a non-empty string.",
      field: :conversation,
      value: value,
      details: details(context, %{operation: :prepare_chat_opts, reason: :invalid_conversation, cause: value})
    )
  end

  def chat_option_error(reason, context),
    do:
      validation(
        "Invalid chat options.",
        :chat_options,
        reason,
        Map.put(to_map(context), :operation, :prepare_chat_opts)
      )

  @spec workflow_error(term(), context()) :: Exception.t()
  def workflow_error(reason, context \\ %{})

  def workflow_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "Workflow execution failed.", :workflow, context)

  def workflow_error({:missing_imported_agent, key}, context) do
    Error.validation_error("Missing imported workflow agent `#{key}`.",
      field: :agents,
      value: detail(context, :agents),
      details: details(context, %{operation: :workflow, reason: :missing_imported_agent, key: key, cause: key})
    )
  end

  def workflow_error({:missing_ref, kind, key}, context) do
    Error.execution_error("Workflow reference could not be resolved.",
      phase: detail(context, :phase, :workflow),
      details:
        details(context, %{operation: :workflow, reason: :missing_ref, ref_kind: kind, key: key, cause: {kind, key}})
    )
  end

  def workflow_error({:missing_field, path, value}, context) do
    Error.execution_error("Workflow output field could not be resolved.",
      phase: detail(context, :phase, :workflow),
      details:
        details(context, %{operation: :workflow, reason: :missing_field, path: path, value: value, cause: {path, value}})
    )
  end

  def workflow_error({:timeout, timeout}, context), do: timeout_error(:workflow, timeout, context)
  def workflow_error(reason, context), do: execution("Workflow execution failed.", :workflow, reason, context)

  @spec handoff_error(term(), context()) :: Exception.t()
  def handoff_error(reason, context \\ %{})

  def handoff_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "Handoff failed.", :handoff, context)

  def handoff_error(:missing_conversation = reason, context) do
    Error.validation_error("Handoff target :auto requires a conversation.",
      field: :conversation,
      details: details(context, %{operation: :handoff, reason: :missing_conversation, cause: reason})
    )
  end

  def handoff_error({:invalid_payload, field} = reason, context) do
    Error.validation_error("Handoff #{field} must be a non-empty string.",
      field: field,
      value: detail(context, :value),
      details: details(context, %{operation: :handoff, reason: :invalid_payload, cause: reason})
    )
  end

  def handoff_error({:peer_not_found, peer} = reason, context) do
    Error.execution_error("Handoff target agent could not be found.",
      phase: :handoff,
      details: details(context, %{operation: :handoff, reason: :peer_not_found, peer: peer, cause: reason})
    )
  end

  def handoff_error({:peer_mismatch, expected, actual} = reason, context) do
    Error.execution_error("Handoff target runtime did not match the configured agent.",
      phase: :handoff,
      details:
        details(context, %{
          operation: :handoff,
          reason: :peer_mismatch,
          expected: expected,
          actual: actual,
          cause: reason
        })
    )
  end

  def handoff_error({:start_failed, reason}, context) do
    Error.execution_error("Handoff target agent could not be started.",
      phase: :handoff,
      details: details(context, %{operation: :handoff, reason: :start_failed, cause: {:start_failed, reason}})
    )
  end

  def handoff_error(reason, context), do: execution("Handoff failed.", :handoff, reason, context)

  @spec subagent_error(term(), context()) :: Exception.t()
  def subagent_error(reason, context \\ %{})

  def subagent_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "Subagent failed.", :subagent, context)

  def subagent_error({:invalid_task, :expected_non_empty_string} = reason, context) do
    Error.validation_error("Subagent task must be a non-empty string.",
      field: :task,
      value: detail(context, :value),
      details: details(context, %{operation: :subagent, reason: :invalid_task, cause: reason})
    )
  end

  def subagent_error({:recursion_limit, limit} = reason, context) do
    Error.validation_error("Subagent delegation is limited to #{limit} nested level.",
      field: :subagent,
      details: details(context, %{operation: :subagent, reason: :recursion_limit, limit: limit, cause: reason})
    )
  end

  def subagent_error({:peer_not_found, peer} = reason, context) do
    Error.execution_error("Subagent peer could not be found.",
      phase: :subagent,
      details: details(context, %{operation: :subagent, reason: :peer_not_found, peer: peer, cause: reason})
    )
  end

  def subagent_error({:peer_mismatch, expected, actual} = reason, context) do
    Error.execution_error("Subagent peer runtime did not match the configured agent.",
      phase: :subagent,
      details:
        details(context, %{
          operation: :subagent,
          reason: :peer_mismatch,
          expected: expected,
          actual: actual,
          cause: reason
        })
    )
  end

  def subagent_error({:timeout, timeout}, context), do: timeout_error(:subagent, timeout, context)

  def subagent_error({:start_failed, reason}, context) do
    Error.execution_error("Subagent could not be started.",
      phase: :subagent,
      details: details(context, %{operation: :subagent, reason: :start_failed, cause: {:start_failed, reason}})
    )
  end

  def subagent_error({:invalid_result, result}, context) do
    Error.execution_error("Subagent returned an invalid result.",
      phase: :subagent,
      details: details(context, %{operation: :subagent, reason: :invalid_result, result: result, cause: result})
    )
  end

  def subagent_error({:child_interrupt, interrupt}, context) do
    Error.execution_error("Subagent interrupted the delegation.",
      phase: :subagent,
      details:
        details(context, %{operation: :subagent, reason: :child_interrupt, interrupt: interrupt, cause: interrupt})
    )
  end

  def subagent_error({:child_error, reason}, context),
    do: execution("Subagent child failed.", :subagent, reason, context)

  def subagent_error(reason, context), do: execution("Subagent failed.", :subagent, reason, context)

  @spec mcp_error(term(), context()) :: Exception.t()
  def mcp_error(reason, context \\ %{})

  def mcp_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "MCP operation failed.", :mcp, context)

  def mcp_error(:jido_ai_not_available = reason, context) do
    Error.config_error("MCP tool sync requires Jido.AI to be available.",
      field: :mcp_tools,
      details: details(context, %{operation: :mcp, reason: :jido_ai_not_available, cause: reason})
    )
  end

  def mcp_error({:tool_limit_exceeded, limits} = reason, context) do
    Error.validation_error("MCP endpoint returned too many tools.",
      field: :mcp_tools,
      value: limits,
      details: details(context, Map.merge(%{operation: :mcp, reason: :tool_limit_exceeded, cause: reason}, limits))
    )
  end

  def mcp_error({:endpoint_already_registered, endpoint} = reason, context) do
    Error.config_error("MCP endpoint #{inspect(endpoint)} is already registered.",
      field: :endpoint,
      value: endpoint,
      details:
        details(context, %{operation: :mcp, reason: :endpoint_already_registered, endpoint: endpoint, cause: reason})
    )
  end

  def mcp_error({:endpoint_conflict, endpoint, existing, incoming} = reason, context) do
    Error.config_error("MCP endpoint #{inspect(endpoint)} is already registered with a different definition.",
      field: :endpoint,
      value: endpoint,
      details:
        details(context, %{
          operation: :mcp,
          reason: :endpoint_conflict,
          endpoint: endpoint,
          existing: existing,
          incoming: incoming,
          cause: reason
        })
    )
  end

  def mcp_error(:not_started = reason, context) do
    Error.execution_error("MCP endpoint is not started.",
      phase: :mcp,
      details: details(context, %{operation: :mcp, reason: :not_started, cause: reason})
    )
  end

  def mcp_error(reason, context) when is_binary(reason) do
    case detail(context, :operation) do
      operation when operation in [:sync_tools, :endpoint_status] ->
        execution("MCP operation failed.", :mcp, reason, context)

      _operation ->
        Error.validation_error(reason,
          field: detail(context, :field, :mcp_tools),
          value: detail(context, :value),
          details: details(context, %{operation: :mcp, cause: reason})
        )
    end
  end

  def mcp_error(reason, context), do: execution("MCP operation failed.", :mcp, reason, context)

  @spec memory_error(atom(), term(), context()) :: Exception.t()
  def memory_error(phase, reason, context \\ %{})

  def memory_error(phase, %_{} = error, context) when is_exception(error) do
    if jidoka_error?(error) do
      error
    else
      memory_exception_error(phase, error, context)
    end
  end

  def memory_error(:retrieve, reason, context) do
    execution("Jidoka memory retrieval failed.", :memory, reason, context, %{phase: :memory_retrieve})
  end

  def memory_error(:capture, reason, context) do
    execution("Jidoka memory capture failed.", :memory, reason, context, %{phase: :memory_capture})
  end

  def memory_error(phase, reason, context) do
    execution("Jidoka memory failed.", :memory, reason, context, %{phase: phase})
  end

  @spec hook_error(atom(), term(), context()) :: Exception.t()
  def hook_error(stage, reason, context \\ %{})

  def hook_error(stage, %_{} = error, context) when is_exception(error) do
    if jidoka_error?(error) do
      error
    else
      Error.execution_error("Lifecycle hook #{stage} failed.",
        phase: :hook,
        details: details(context, %{operation: :hook, stage: stage, cause: error})
      )
    end
  end

  def hook_error(stage, reason, context) do
    Error.execution_error("Lifecycle hook #{stage} failed.",
      phase: :hook,
      details: details(context, %{operation: :hook, stage: stage, cause: reason})
    )
  end

  @spec guardrail_error(atom(), term(), term(), context()) :: Exception.t()
  def guardrail_error(stage, label, reason, context \\ %{})

  def guardrail_error(stage, label, %_{} = error, context) when is_exception(error) do
    if jidoka_error?(error) do
      error
    else
      Error.execution_error("Control #{label} blocked #{stage}.",
        phase: :guardrail,
        details: details(context, %{operation: :guardrail, stage: stage, label: label, cause: error})
      )
    end
  end

  def guardrail_error(stage, label, reason, context) do
    Error.execution_error("Control #{label} blocked #{stage}.",
      phase: :guardrail,
      details: details(context, %{operation: :guardrail, stage: stage, label: label, cause: reason})
    )
  end

  @spec debug_error(term(), context()) :: Exception.t()
  def debug_error(reason, context \\ %{})

  def debug_error(%_{} = error, context) when is_exception(error),
    do: passthrough_or_execution(error, "Jidoka debug lookup failed.", :debug, context)

  def debug_error(:request_not_found = reason, context) do
    Error.validation_error("Jidoka request could not be found.",
      field: :request_id,
      value: detail(context, :request_id),
      details: details(context, %{operation: :debug, reason: :request_not_found, cause: reason})
    )
  end

  def debug_error(:debug_not_enabled = reason, context) do
    Error.config_error("Jidoka debug buffer is not enabled.",
      field: :debug,
      details: details(context, %{operation: :debug, reason: :debug_not_enabled, cause: reason})
    )
  end

  def debug_error(reason, context), do: execution("Jidoka debug lookup failed.", :debug, reason, context)
end
