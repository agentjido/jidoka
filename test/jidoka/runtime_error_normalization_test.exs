defmodule JidokaTest.RuntimeErrorNormalizationTest do
  use JidokaTest.Support.Case, async: false

  @moduletag :capture_log

  alias Jido.AI.Request

  alias JidokaTest.{
    ChatAgent,
    FailingMCPSync,
    GuardrailedAgent,
    MemoryAgent,
    MissingPeerOrchestratorAgent,
    OrchestratorAgent
  }

  alias JidokaTest.Workflow.FailingWorkflow

  defmodule StringFailingMCPSync do
    def run(_params, _context), do: {:error, "sync command failed"}
  end

  defmodule ExceptionFailingMCPSync do
    def run(_params, _context), do: {:error, RuntimeError.exception("sync exploded")}
  end

  setup do
    previous_sync_module = Application.get_env(:jidoka, :mcp_sync_module)

    on_exit(fn ->
      if previous_sync_module do
        Application.put_env(:jidoka, :mcp_sync_module, previous_sync_module)
      else
        Application.delete_env(:jidoka, :mcp_sync_module)
      end
    end)

    :ok
  end

  test "Jidoka.chat wraps missing runtime ids" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.chat("missing-runtime-normalization-agent", "hello")

    assert error.details.operation == :chat
    assert error.details.reason == :not_found
    assert error.details.cause == :not_found
    assert Jidoka.format_error(error) == "Jidoka agent could not be found."
  end

  test "Jidoka.chat wraps stopped runtime pids" do
    assert {:ok, pid} = ChatAgent.start_link(id: "runtime-stopped-pid-normalization")
    assert :ok = Jidoka.stop_agent(pid)
    refute Process.alive?(pid)

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.chat(pid, "hello")

    assert error.details.operation == :chat
    assert error.details.reason == :not_found
    assert error.details.cause == :not_found
    assert error.details.target == pid
    assert Jidoka.format_error(error) == "Jidoka agent could not be found."
  end

  test "Jidoka.chat validates conversation before routing or server lookup" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.chat("missing-runtime-normalization-agent", "hello", conversation: "")

    assert error.details.operation == :prepare_chat_opts
    assert error.details.reason == :invalid_conversation
    assert Jidoka.format_error(error) == "conversation must be a non-empty string."
  end

  test "Jidoka.chat returns beginner-readable invalid context errors" do
    try do
      assert {:error, %Jidoka.Error.ValidationError{} = error} =
               Jidoka.chat(ChatAgent, "hello", context: [:bad])

      assert error.field == :context
      assert error.details.reason == :expected_map
      assert Jidoka.format_error(error) == "Invalid context: pass `context:` as a map or keyword list."
    after
      case Jidoka.whereis(ChatAgent.id()) do
        pid when is_pid(pid) -> Jidoka.stop_agent(pid)
        nil -> :ok
      end
    end
  end

  test "prepare_chat_opts wraps malformed request hook specs" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([hooks: [1, 2]], nil)

    assert error.details.operation == :prepare_chat_opts
    assert error.details.reason == :invalid_hook_spec
    assert error.details.cause =~ "hooks must be a keyword list or map"
  end

  test "workflow failures preserve the raw cause" do
    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             FailingWorkflow.run(%{reason: "normalized boom"})

    assert error.details.workflow_id == "failing_workflow"
    assert error.details.step == :fail
    assert error.details.cause == "normalized boom"
    assert Jidoka.format_error(error) == "Workflow failing_workflow step fail failed."
  end

  test "subagent tools wrap peer lookup failures" do
    tool = find_tool(MissingPeerOrchestratorAgent, "research_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             tool.run(%{task: "Find peer"}, %{})

    assert error.details.operation == :subagent
    assert error.details.agent_id == "research_agent"
    assert error.details.reason == :peer_not_found
    assert error.details.cause == {:peer_not_found, "missing-peer-test"}
  end

  test "MCP sync wraps command failures at the public helper boundary" do
    Application.put_env(:jidoka, :mcp_sync_module, FailingMCPSync)

    with_isolated_mcp_pool(fn ->
      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.MCP.sync_tools(
                 self(),
                 [endpoint: :runtime_error_sync, prefix: "err_", replace_existing: false] ++
                   runtime_endpoint_attrs()
               )

      assert error.details.operation == :mcp
      assert error.details.cause == :server_capabilities_not_set
      assert Jidoka.format_error(error) == "MCP operation failed."
    end)
  end

  test "MCP sync treats string command failures as execution errors" do
    Application.put_env(:jidoka, :mcp_sync_module, StringFailingMCPSync)

    with_isolated_mcp_pool(fn ->
      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.MCP.sync_tools(
                 self(),
                 [endpoint: :runtime_string_error_sync, prefix: "err_", replace_existing: false] ++
                   runtime_endpoint_attrs()
               )

      assert error.details.operation == :mcp
      assert error.details.cause == "sync command failed"
      assert Jidoka.format_error(error) == "MCP operation failed."
    end)
  end

  test "MCP sync wraps third-party exception structs instead of leaking them" do
    Application.put_env(:jidoka, :mcp_sync_module, ExceptionFailingMCPSync)

    with_isolated_mcp_pool(fn ->
      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.MCP.sync_tools(
                 self(),
                 [endpoint: :runtime_exception_error_sync, prefix: "err_", replace_existing: false] ++
                   runtime_endpoint_attrs()
               )

      assert %RuntimeError{message: "sync exploded"} = error.details.cause
      assert Jidoka.format_error(error) == "MCP operation failed."
    end)
  end

  test "memory retrieval failures are hard structured request errors" do
    runtime = MemoryAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, updated_agent,
            {:ai_react_request_error, %{request_id: "req-memory-normalized", reason: :memory_failed}}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "remember", request_id: "req-memory-normalized", tool_context: %{}}}
             )

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Request.get_result(updated_agent, "req-memory-normalized")

    assert error.details.reason == :missing_context
    assert error.details.key == :session
    assert Jidoka.format_error(error) =~ "Missing required context key `session`"
  end

  test "memory capture failures are soft structured warnings" do
    error = Jidoka.Error.Normalize.memory_error(:capture, :write_failed, agent_id: "memory_agent")

    assert %Jidoka.Error.ExecutionError{} = error
    assert error.details.phase == :memory_capture
    assert error.details.cause == :write_failed
    assert Jidoka.format_error(error) == "Jidoka memory capture failed."
  end

  test "hook callback failures return structured execution errors" do
    assert {:ok, pid} = ChatAgent.start_link(id: "runtime-hook-error-normalization")

    try do
      bad_hook = fn _input -> {:ok, [1, 2]} end

      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.chat(pid, "hello", hooks: [before_turn: bad_hook])

      assert error.details.operation == :hook
      assert error.details.stage == :before_turn
      assert error.details.cause =~ "before_turn hook must return"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "hook exceptions are normalized without crashing the agent" do
    assert {:ok, pid} = ChatAgent.start_link(id: "runtime-hook-exception-normalization")

    try do
      raising_hook = fn _input -> raise "hook boom" end

      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.chat(pid, "hello", hooks: [before_turn: raising_hook])

      assert error.details.operation == :hook
      assert error.details.stage == :before_turn
      assert error.details.cause =~ "hook boom"
      assert Process.alive?(pid)
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "guardrail blocks return structured execution errors" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "runtime-guardrail-error-normalization")

    try do
      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.chat(pid, "hello", guardrails: [input: fn _input -> {:error, :blocked_for_test} end])

      assert error.details.operation == :guardrail
      assert error.details.stage == :input
      assert error.details.label == "anonymous_guardrail"
      assert error.details.cause == :blocked_for_test
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "guardrail exceptions are normalized without crashing the agent" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "runtime-guardrail-exception-normalization")

    try do
      raising_guardrail = fn _input -> raise "guardrail boom" end

      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.chat(pid, "hello", guardrails: [input: raising_guardrail])

      assert error.details.operation == :guardrail
      assert error.details.stage == :input
      assert error.details.label == "anonymous_guardrail"
      assert error.details.cause =~ "guardrail boom"
      assert Process.alive?(pid)
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "subagent validation errors are structured" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Subagent.run_subagent(
               hd(OrchestratorAgent.subagents()),
               %{task: ""},
               %{}
             )

    assert error.details.operation == :subagent
    assert error.details.reason == :invalid_task
    assert error.details.cause == {:invalid_task, :expected_non_empty_string}
  end

  defp runtime_endpoint_attrs do
    [
      transport: {:stdio, command: "echo"},
      client_info: %{name: "jidoka-runtime-error-test", version: "0.1.0"},
      timeouts: %{request_ms: 15_000}
    ]
  end

  defp with_isolated_mcp_pool(fun) do
    previous_state = :sys.get_state(Jido.MCP.ClientPool)

    try do
      fun.()
    after
      :sys.replace_state(Jido.MCP.ClientPool, fn _state -> previous_state end)
    end
  end
end
