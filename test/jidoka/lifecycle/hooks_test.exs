defmodule JidokaTest.HooksTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    ChatAgent,
    HookCallbacks,
    HookedAgent,
    InjectTenantHook,
    InterruptingAgent,
    NormalizeReplyHook,
    NotifyOpsHook
  }

  test "wraps Jidoka.Hook with published names" do
    assert Jidoka.Hook.validate_hook_module(InjectTenantHook) == :ok
    assert {:ok, "inject_tenant"} = Jidoka.Hook.hook_name(InjectTenantHook)

    assert {:ok, ["inject_tenant", "normalize_reply"]} =
             Jidoka.Hook.hook_names([InjectTenantHook, NormalizeReplyHook])
  end

  test "exposes configured hooks by stage" do
    assert HookedAgent.hooks() == %{
             before_turn: [InjectTenantHook, {HookCallbacks, :before_turn, ["dsl_mfa"]}],
             after_turn: [NormalizeReplyHook, {HookCallbacks, :after_turn, ["!"]}],
             on_interrupt: [NotifyOpsHook, {HookCallbacks, :notify_interrupt, ["dsl_mfa"]}]
           }

    assert HookedAgent.before_turn_hooks() ==
             [InjectTenantHook, {HookCallbacks, :before_turn, ["dsl_mfa"]}]

    assert HookedAgent.after_turn_hooks() ==
             [NormalizeReplyHook, {HookCallbacks, :after_turn, ["!"]}]

    assert HookedAgent.interrupt_hooks() ==
             [NotifyOpsHook, {HookCallbacks, :notify_interrupt, ["dsl_mfa"]}]
  end

  test "accepts request-scoped module, MFA, and function hooks" do
    runtime_fun = fn %Jidoka.Hooks.BeforeTurn{} = input ->
      sequence = Map.get(input.metadata, :sequence, [])
      {:ok, %{metadata: %{sequence: sequence ++ ["runtime_fn"]}}}
    end

    assert {:ok, opts} =
             Jidoka.Agent.prepare_chat_opts(
               [
                 context: %{tenant: "runtime"},
                 hooks: [
                   before_turn: [
                     InjectTenantHook,
                     {HookCallbacks, :before_turn, ["runtime_mfa"]},
                     runtime_fun
                   ]
                 ]
               ],
               nil
             )

    tool_context = Keyword.fetch!(opts, :tool_context)

    assert %{
             before_turn: [
               InjectTenantHook,
               {HookCallbacks, :before_turn, ["runtime_mfa"]},
               ^runtime_fun
             ]
           } = tool_context[:__jidoka_hooks__]
  end

  test "rejects malformed request-scoped hook specs with a validation error" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([hooks: [1, 2]], nil)

    assert error.field == :hooks
    assert error.details.reason == :invalid_hook_spec
    assert error.message =~ "hooks must be a keyword list or map"
  end

  test "fails malformed before_turn override lists cleanly instead of raising" do
    assert {:ok, pid} = ChatAgent.start_link(id: "invalid-hook-override-test")

    bad_hook = fn _input -> {:ok, [1, 2]} end

    try do
      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               Jidoka.chat(pid, "hello", hooks: [before_turn: bad_hook])

      assert error.message == "Lifecycle hook before_turn failed."
      assert error.details.stage == :before_turn
      assert error.details.cause =~ "before_turn hook must return {:ok, map_or_keyword_overrides}"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "runs before_turn hooks in declaration order and rewrites request params" do
    runtime = HookedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, updated_agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "hello", request_id: "req-hook-1", tool_context: %{notify_pid: self()}}}
             )

    assert params.query == "hello for acme"

    assert Jidoka.Context.strip_internal(params.tool_context) == %{
             notify_pid: self(),
             tenant: "acme"
           }

    assert params.allowed_tools == ["add_numbers"]
    assert params.llm_opts == [temperature: 0.1]

    assert get_in(updated_agent.state, [
             :requests,
             "req-hook-1",
             :meta,
             :jidoka_hooks,
             :metadata,
             :sequence
           ]) == ["inject_tenant", "dsl_mfa"]
  end

  test "runs after_turn hooks in reverse order for successful outcomes" do
    runtime = HookedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    {:ok, agent, _action} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start, %{query: "hello", request_id: "req-hook-2", tool_context: %{notify_pid: self()}}}
      )

    agent = Jido.AI.Request.complete_request(agent, "req-hook-2", "done")

    assert {:ok, updated_agent, []} =
             runtime.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-hook-2"}}, [])

    assert Jido.AI.Request.get_result(updated_agent, "req-hook-2") == {:ok, "normalized:done!"}
  end

  test "runs after_turn hooks in reverse order for failed outcomes" do
    runtime = HookedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    {:ok, agent, _action} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start, %{query: "hello", request_id: "req-hook-3", tool_context: %{notify_pid: self()}}}
      )

    agent = Jido.AI.Request.fail_request(agent, "req-hook-3", :boom)

    assert {:ok, updated_agent, []} =
             runtime.on_after_cmd(agent, {:ai_react_start, %{request_id: "req-hook-3"}}, [])

    assert Jido.AI.Request.get_result(updated_agent, "req-hook-3") ==
             {:error, {:normalized_error, {"!", :boom}}}
  end

  test "stores hook metadata per request" do
    runtime = HookedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    {:ok, agent, _action} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start, %{query: "first", request_id: "req-hook-4", tool_context: %{notify_pid: self()}}}
      )

    {:ok, agent, _action} =
      runtime.on_before_cmd(
        agent,
        {:ai_react_start, %{query: "second", request_id: "req-hook-5", tool_context: %{notify_pid: self()}}}
      )

    assert get_in(agent.state, [:requests, "req-hook-4", :meta, :jidoka_hooks, :message]) ==
             "first for acme"

    assert get_in(agent.state, [:requests, "req-hook-5", :meta, :jidoka_hooks, :message]) ==
             "second for acme"
  end

  test "translates default hook interrupts from MyAgent.chat and runs interrupt hooks" do
    assert {:ok, pid} = InterruptingAgent.start_link(id: "interrupting-agent-test")

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :approval, message: "Approval required"}} =
               InterruptingAgent.chat(pid, "Refund this order", context: [notify_pid: self()])

      assert_receive {:hook_interrupt, :approval, :before_turn}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "translates failed interrupt envelopes from tool guardrails" do
    interrupt = Jidoka.Interrupt.new(kind: :approval, message: "Need approval")

    assert Jidoka.Hooks.translate_chat_result({:error, {:failed, :error, {:interrupt, interrupt}}}) ==
             {:interrupt, interrupt}
  end

  test "translates request-scoped interrupt hooks from Jidoka.chat and supports runtime functions" do
    assert {:ok, pid} = ChatAgent.start_link(id: "runtime-hook-agent-test")
    test_pid = self()

    before_turn = fn _input ->
      {:interrupt,
       %{
         kind: :manual_review,
         message: "Manual review required",
         data: %{notify_pid: test_pid, from: :runtime}
       }}
    end

    on_interrupt = fn %Jidoka.Hooks.InterruptInput{interrupt: interrupt} ->
      send(test_pid, {:runtime_interrupt, interrupt.kind})
      :ok
    end

    try do
      assert {:interrupt, %Jidoka.Interrupt{kind: :manual_review}} =
               Jidoka.chat(pid, "Check this request",
                 context: [notify_pid: self()],
                 hooks: [before_turn: before_turn, on_interrupt: on_interrupt]
               )

      assert_receive {:runtime_interrupt, :manual_review}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end
end
