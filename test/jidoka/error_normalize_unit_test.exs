defmodule JidokaTest.ErrorNormalizeUnitTest do
  use ExUnit.Case, async: true

  alias Jidoka.Error
  alias Jidoka.Error.Normalize

  test "chat errors normalize passthroughs, handoffs, timeouts, and generic failures" do
    existing = Error.validation_error("already normalized")
    assert Normalize.chat_error(existing) == existing

    handoff =
      Jidoka.Handoff.new(
        conversation_id: "case-123",
        from_agent: "triage",
        to_agent: __MODULE__,
        to_agent_id: "specialist",
        name: "specialist",
        message: "Take this one",
        context: %{}
      )

    assert Normalize.chat_error({:handoff, handoff}) == {:handoff, handoff}

    assert %Error.ExecutionError{phase: :chat, details: %{reason: :timeout, timeout: 250}} =
             Normalize.chat_error({:timeout, 250})

    assert %Error.ExecutionError{phase: :chat, details: %{cause: :boom}} =
             Normalize.chat_error({:failed, :failed, :boom})
  end

  test "chat option errors map request option failures to specific fields" do
    cases = [
      {{:invalid_control_spec, "bad controls"}, :controls, :invalid_control_spec},
      {{:invalid_hook_stage, :during_turn}, :hooks, :invalid_hook_stage},
      {{:invalid_control_stage, :during_turn}, :controls, :invalid_control_stage},
      {{:invalid_hook, :before_turn, "bad hook"}, :hooks, :invalid_hook},
      {{:invalid_control, :input, "bad control"}, :controls, :invalid_control},
      {{:invalid_character, "bad character"}, :character, :invalid_character}
    ]

    for {reason, field, expected_reason} <- cases do
      assert %Error.ValidationError{field: ^field, details: %{reason: ^expected_reason}} =
               Normalize.chat_option_error(reason, value: :bad)
    end

    assert %Error.ValidationError{field: :chat_options, details: %{cause: :unknown_option}} =
             Normalize.chat_option_error(:unknown_option, value: :bad)
  end

  test "workflow errors preserve missing refs, missing fields, timeouts, and passthroughs" do
    existing = Error.execution_error("already normalized")
    assert Normalize.workflow_error(existing) == existing

    assert %Error.ValidationError{field: :agents, details: %{reason: :missing_imported_agent, key: :writer}} =
             Normalize.workflow_error({:missing_imported_agent, :writer}, agents: %{})

    assert %Error.ExecutionError{phase: :step, details: %{reason: :missing_ref, ref_kind: :context, key: :session}} =
             Normalize.workflow_error({:missing_ref, :context, :session}, phase: :step)

    assert %Error.ExecutionError{details: %{reason: :missing_field, path: [:result, :score]}} =
             Normalize.workflow_error({:missing_field, [:result, :score], %{}})

    assert %Error.ExecutionError{phase: :workflow, details: %{reason: :timeout, timeout: 10}} =
             Normalize.workflow_error({:timeout, 10})
  end

  test "handoff errors cover validation and peer failure branches" do
    assert %Error.ValidationError{field: :conversation, details: %{reason: :missing_conversation}} =
             Normalize.handoff_error(:missing_conversation)

    assert %Error.ValidationError{field: :message, details: %{reason: :invalid_payload}} =
             Normalize.handoff_error({:invalid_payload, :message}, value: "")

    assert %Error.ExecutionError{phase: :handoff, details: %{reason: :peer_not_found, peer: "agent-1"}} =
             Normalize.handoff_error({:peer_not_found, "agent-1"})

    assert %Error.ExecutionError{details: %{reason: :peer_mismatch, expected: Expected, actual: Actual}} =
             Normalize.handoff_error({:peer_mismatch, Expected, Actual})

    assert %Error.ExecutionError{details: %{reason: :start_failed, cause: {:start_failed, :boom}}} =
             Normalize.handoff_error({:start_failed, :boom})
  end

  test "subagent errors cover all child outcome branches" do
    interrupt = Jidoka.Interrupt.new(id: "approval", message: "Approve", data: %{})

    cases = [
      {{:peer_mismatch, Expected, Actual}, :peer_mismatch},
      {{:timeout, 50}, :timeout},
      {{:start_failed, :boom}, :start_failed},
      {{:invalid_result, :bad}, :invalid_result},
      {{:child_interrupt, interrupt}, :child_interrupt}
    ]

    for {reason, expected_reason} <- cases do
      assert %Error.ExecutionError{phase: :subagent, details: %{reason: ^expected_reason}} =
               Normalize.subagent_error(reason)
    end

    assert %Error.ExecutionError{phase: :subagent, details: %{cause: :child_boom}} =
             Normalize.subagent_error({:child_error, :child_boom})
  end

  test "mcp errors cover config, validation, conflict, runtime, and string modes" do
    assert %Error.ConfigError{field: :mcp_tools, details: %{reason: :jido_ai_not_available}} =
             Normalize.mcp_error(:jido_ai_not_available)

    assert %Error.ValidationError{field: :mcp_tools, details: %{reason: :tool_limit_exceeded, max: 1}} =
             Normalize.mcp_error({:tool_limit_exceeded, %{max: 1}})

    assert %Error.ConfigError{field: :endpoint, details: %{reason: :endpoint_already_registered}} =
             Normalize.mcp_error({:endpoint_already_registered, :docs})

    assert %Error.ConfigError{field: :endpoint, details: %{reason: :endpoint_conflict}} =
             Normalize.mcp_error({:endpoint_conflict, :docs, %{a: 1}, %{a: 2}})

    assert %Error.ExecutionError{phase: :mcp, details: %{reason: :not_started}} =
             Normalize.mcp_error(:not_started)

    assert %Error.ExecutionError{phase: :mcp, details: %{cause: "sync failed"}} =
             Normalize.mcp_error("sync failed", operation: :sync_tools)

    assert %Error.ValidationError{field: :endpoint, details: %{cause: "bad endpoint"}} =
             Normalize.mcp_error("bad endpoint", field: :endpoint, value: :bad)
  end

  test "memory, hook, guardrail, and debug errors preserve passthroughs and exception causes" do
    existing = Error.config_error("already normalized")
    assert Normalize.memory_error(:retrieve, existing) == existing
    assert Normalize.hook_error(:before_turn, existing) == existing
    assert Normalize.guardrail_error(:input, "safe", existing) == existing

    assert %Error.ExecutionError{details: %{phase: :memory_retrieve, cause: %RuntimeError{message: "memory"}}} =
             Normalize.memory_error(:retrieve, RuntimeError.exception("memory"))

    assert %Error.ExecutionError{phase: :hook, details: %{stage: :after_turn, cause: %RuntimeError{}}} =
             Normalize.hook_error(:after_turn, RuntimeError.exception("hook"))

    assert %Error.ExecutionError{phase: :guardrail, details: %{stage: :output, label: "safe"}} =
             Normalize.guardrail_error(:output, "safe", RuntimeError.exception("guardrail"))

    assert %Error.ValidationError{field: :request_id, details: %{reason: :request_not_found}} =
             Normalize.debug_error(:request_not_found, request_id: "req-1")

    assert %Error.ConfigError{field: :debug, details: %{reason: :debug_not_enabled}} =
             Normalize.debug_error(:debug_not_enabled)
  end
end
