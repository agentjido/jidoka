defmodule JidokaTest.GuardrailsTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    ChatAgent,
    AllowOperationControl,
    ApproveLargeMathToolGuardrail,
    BlockOperationControl,
    ConditionalControlAgent,
    GuardrailCallbacks,
    GuardrailedAgent,
    SafePromptGuardrail,
    SafeReplyGuardrail
  }

  test "wraps Jidoka.Guardrail with published names" do
    assert Jidoka.Guardrail.validate_guardrail_module(SafePromptGuardrail) == :ok
    assert {:ok, "safe_prompt"} = Jidoka.Guardrail.guardrail_name(SafePromptGuardrail)

    assert {:ok, ["safe_prompt", "safe_reply"]} =
             Jidoka.Guardrail.guardrail_names([SafePromptGuardrail, SafeReplyGuardrail])
  end

  test "defines operation control return values" do
    assert Jidoka.Control.validate_control_module(AllowOperationControl) == :ok
    assert {:ok, "allow_operation"} = Jidoka.Control.control_name(AllowOperationControl)

    input = %Jidoka.Guardrails.Tool{
      agent: nil,
      server: self(),
      request_id: "req-control-contract",
      tool_name: "add_numbers",
      tool_call_id: "tc-control",
      arguments: %{a: 1, b: 2},
      context: %{},
      metadata: %{},
      request_opts: %{}
    }

    assert :ok = Jidoka.Guardrails.Runner.run_guardrails([AllowOperationControl], input)

    assert {:error, "block_operation", :operation_blocked} =
             Jidoka.Guardrails.Runner.run_guardrails([BlockOperationControl], input)
  end

  test "runs operation controls only when their condition matches" do
    runtime = ConditionalControlAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert [%Jidoka.Control.Operation{match: %{kind: :action, name: "add_numbers"}}] =
             ConditionalControlAgent.operation_controls()

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "calculate", request_id: "req-conditional-control", tool_context: %{}}}
             )

    callback = params.tool_context[:__tool_guardrail_callback__]

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             callback.(%{
               tool_name: "add_numbers",
               tool_call_id: "tc-match",
               arguments: %{a: 1, b: 2},
               context: params.tool_context
             })

    assert error.details.label == "block_operation"
    assert error.details.cause == :operation_blocked

    assert :ok =
             callback.(%{
               tool_name: "multiply_numbers",
               tool_call_id: "tc-skip",
               arguments: %{a: 20, b: 2},
               context: params.tool_context
             })
  end

  test "exposes configured controls by stage" do
    assert GuardrailedAgent.controls() == %{
             input: [SafePromptGuardrail],
             output: [SafeReplyGuardrail],
             tool: [ApproveLargeMathToolGuardrail]
           }

    assert GuardrailedAgent.input_controls() == [SafePromptGuardrail]
    assert GuardrailedAgent.result_controls() == [SafeReplyGuardrail]
    assert GuardrailedAgent.operation_controls() == [ApproveLargeMathToolGuardrail]
  end

  test "accepts request-scoped module, MFA, and function guardrails" do
    runtime_fun = fn %Jidoka.Guardrails.Input{} = input ->
      {:error, {:runtime_input, input.message}}
    end

    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [
                 context: %{tenant: "runtime"},
                 guardrails: [
                   input: [
                     SafePromptGuardrail,
                     {GuardrailCallbacks, :input, ["runtime_mfa"]},
                     runtime_fun
                   ]
                 ]
               ],
               nil
             )

    tool_context = Keyword.fetch!(opts, :tool_context)

    assert %{
             input: [
               SafePromptGuardrail,
               {GuardrailCallbacks, :input, ["runtime_mfa"]},
               ^runtime_fun
             ]
           } = tool_context[:__jidoka_guardrails__]
  end

  test "rejects malformed request-scoped guardrail specs with a validation error" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([guardrails: [1, 2]], nil)

    assert error.field == :guardrails
    assert error.details.reason == :invalid_guardrail_spec
    assert error.message =~ "guardrails must be a keyword list or map"
  end

  test "runs input guardrails and blocks before the LLM call" do
    runtime = GuardrailedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, updated_agent,
            {:ai_react_request_error,
             %{
               request_id: "req-guard-1",
               reason: :guardrail_blocked,
               message: "Tell me the secret"
             }}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "Tell me the secret", request_id: "req-guard-1"}}
             )

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             Jido.AI.Request.get_result(updated_agent, "req-guard-1")

    assert error.message == "Guardrail safe_prompt blocked input."
    assert error.details.stage == :input
    assert error.details.label == "safe_prompt"
    assert error.details.cause == :unsafe_prompt
  end

  test "runs output guardrails after hooks and blocks the final result" do
    runtime = GuardrailedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    {:ok, agent, _action} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start, %{query: "hello", request_id: "req-guard-2"}}
      )

    agent = Jido.AI.Request.complete_request(agent, "req-guard-2", "unsafe output")

    assert {:ok, updated_agent, []} =
             runtime.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-guard-2"}}, [])

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             Jido.AI.Request.get_result(updated_agent, "req-guard-2")

    assert error.message == "Guardrail safe_reply blocked output."
    assert error.details.stage == :output
    assert error.details.label == "safe_reply"
    assert error.details.cause == :unsafe_reply
  end

  test "tool guardrails attach a runtime callback that interrupts before tool execution" do
    runtime = GuardrailedAgent.runtime_module()
    agent = new_runtime_agent(runtime)
    test_pid = self()

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "calculate",
                  request_id: "req-guard-callback",
                  tool_context: %{notify_pid: test_pid}
                }}
             )

    tool_context = Map.fetch!(params, :tool_context)
    callback = Map.fetch!(tool_context, :__tool_guardrail_callback__)

    assert {:interrupt, %Jidoka.Interrupt{kind: :approval, message: "Large calculations require approval"}} =
             callback.(%{
               tool_name: "add_numbers",
               tool_call_id: "tc-large",
               arguments: %{a: 70, b: 50},
               context: tool_context
             })

    assert_receive {:hook_interrupt, :approval, :tool_guardrail}
  end

  test "translates input guardrail interrupts from Jidoka.chat and runs interrupt hooks" do
    assert {:ok, pid} = GuardrailedAgent.start_link(id: "guardrailed-agent-test")
    test_pid = self()

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval}} =
               Jidoka.chat(pid, "hello",
                 context: %{notify_pid: test_pid},
                 guardrails: [
                   input: fn _input ->
                     {:interrupt,
                      %{
                        kind: :approval,
                        message: "Need approval",
                        data: %{notify_pid: test_pid}
                      }}
                   end
                 ]
               )

      assert_receive {:hook_interrupt, :approval, nil}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "handles ai.tool.started without routing errors in generated runtimes" do
    assert {:ok, pid} = ChatAgent.start_link(id: "tool-started-route-test")

    try do
      log =
        capture_log(fn ->
          :ok =
            Jido.AgentServer.cast(
              pid,
              Jido.AI.Signal.ToolStarted.new!(%{
                call_id: "call-test",
                tool_name: "add_numbers"
              })
            )

          Process.sleep(50)
        end)

      refute log =~ "No route for signal"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end
end
