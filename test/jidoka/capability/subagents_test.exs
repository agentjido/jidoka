defmodule JidokaTest.SubagentsTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.{
    ContextPeerNoForwardOrchestratorAgent,
    ContextPeerOrchestratorAgent,
    ControlledSubagentOrchestratorAgent,
    ForwardExceptOrchestratorAgent,
    ForwardNoneOrchestratorAgent,
    ForwardOnlyOrchestratorAgent,
    InvalidInterruptOrchestratorAgent,
    InterruptOrchestratorAgent,
    InvalidResultOrchestratorAgent,
    MissingPeerOrchestratorAgent,
    OrchestratorAgent,
    PeerOrchestratorAgent,
    RaisingOrchestratorAgent,
    ResearchSpecialist,
    ReviewSpecialist,
    StartFailureOrchestratorAgent,
    StartIgnoreOrchestratorAgent,
    StartTripleOrchestratorAgent,
    StructuredInvalidResultOrchestratorAgent,
    StructuredMapOrchestratorAgent,
    StructuredOrchestratorAgent,
    TimeoutOrchestratorAgent,
    WrongPeerOrchestratorAgent
  }

  test "exposes configured subagent definitions and names" do
    assert Enum.map(OrchestratorAgent.subagents(), & &1.name) == [
             "research_agent",
             "review_specialist"
           ]

    assert OrchestratorAgent.subagent_names() == ["research_agent", "review_specialist"]
  end

  test "merges generated subagent tools into the agent tool registry" do
    assert Enum.sort(OrchestratorAgent.tool_names()) == ["research_agent", "review_specialist"]

    assert Enum.all?(OrchestratorAgent.tools(), fn tool_module ->
             String.starts_with?(tool_module.name(), ["research_agent", "review_specialist"])
           end)
  end

  test "runs ephemeral subagents through generated tool modules and forwards public context only" do
    research_tool = find_tool(OrchestratorAgent, "research_agent")
    agent_id = "subagent-parent-ephemeral"
    request_id = "req-subagent-ephemeral-1"

    context = %{
      "tenant" => "acme",
      "notify_pid" => self(),
      "memory" => %{prompt: "should not forward"},
      :__jidoka_hooks__ => %{before_turn: [:demo]},
      Jidoka.Subagent.server_key() => self(),
      Jidoka.Subagent.request_id_key() => request_id,
      Jidoka.Trace.agent_id_key() => agent_id,
      :session => "session-subagent",
      :conversation_id => "conv-subagent",
      :context_ref => "default",
      Jidoka.Subagent.depth_key() => 0
    }

    assert {:ok, %{result: "research:Summarize the issue:tenant=acme:depth=1"}} =
             research_tool.run(%{task: "Summarize the issue"}, context)

    assert_receive {:research_specialist_context, forwarded_context}
    assert forwarded_context["tenant"] == "acme"
    assert forwarded_context["notify_pid"] == self()
    assert forwarded_context[Jidoka.Subagent.depth_key()] == 1
    refute Map.has_key?(forwarded_context, :memory)
    refute Map.has_key?(forwarded_context, "memory")
    refute Map.has_key?(forwarded_context, :__jidoka_hooks__)

    assert [%{name: "research_agent", mode: :ephemeral, outcome: :ok, child_id: child_id}] =
             Jidoka.Subagent.request_calls(self(), request_id)

    assert {:ok, trace} = Jidoka.Trace.for_request(agent_id, request_id)

    assert [
             %{event: :start, metadata: start_metadata},
             %{event: :stop, status: :completed, metadata: stop_metadata}
           ] = Enum.filter(trace.events, &(&1.category == :subagent))

    assert start_metadata.input_keys == ["task"]
    assert start_metadata.session_id == "session-subagent"
    assert start_metadata.conversation_id == "conv-subagent"
    assert start_metadata.context_ref == "default"

    assert stop_metadata.child_id == child_id
    assert stop_metadata.context_keys == ["context_ref", "conversation_id", "notify_pid", "session", "tenant"]
    assert stop_metadata.mode == :ephemeral
    assert stop_metadata.outcome == :ok
    assert stop_metadata.result_preview == "research:Summarize the issue:tenant=acme:depth=1"
  end

  test "supports disabling context forwarding" do
    research_tool = find_tool(ForwardNoneOrchestratorAgent, "research_agent")

    assert {:ok, %{result: "research:No context:tenant=none:depth=1"}} =
             research_tool.run(
               %{task: "No context"},
               %{tenant: "acme", notify_pid: self(), secret: "drop"}
             )

    refute_receive {:research_specialist_context, _context}
  end

  test "supports only-list context forwarding" do
    research_tool = find_tool(ForwardOnlyOrchestratorAgent, "research_agent")

    assert {:ok, %{result: "research:Only context:tenant=acme:depth=1"}} =
             research_tool.run(
               %{task: "Only context"},
               %{tenant: "acme", notify_pid: self(), secret: "drop", memory: %{drop: true}}
             )

    assert_receive {:research_specialist_context, forwarded_context}
    assert forwarded_context[:tenant] == "acme"
    assert forwarded_context[:notify_pid] == self()
    assert forwarded_context[Jidoka.Subagent.depth_key()] == 1
    refute Map.has_key?(forwarded_context, :secret)
    refute Map.has_key?(forwarded_context, :memory)
  end

  test "supports except-list context forwarding" do
    research_tool = find_tool(ForwardExceptOrchestratorAgent, "research_agent")

    assert {:ok, %{result: "research:Except context:tenant=acme:depth=1"}} =
             research_tool.run(
               %{task: "Except context"},
               %{tenant: "acme", notify_pid: self(), secret: "drop"}
             )

    assert_receive {:research_specialist_context, forwarded_context}
    assert forwarded_context[:tenant] == "acme"
    assert forwarded_context[:notify_pid] == self()
    refute Map.has_key?(forwarded_context, :secret)
  end

  test "supports structured parent-visible subagent results" do
    research_tool = find_tool(StructuredOrchestratorAgent, "research_agent")

    assert {:ok, %{result: result, subagent: metadata}} =
             research_tool.run(%{task: "Structured task"}, %{tenant: "structured"})

    assert result == "research:Structured task:tenant=structured:depth=1"
    assert metadata.name == "research_agent"
    assert metadata.mode == :ephemeral
    assert metadata.outcome == :ok
    assert metadata.result_preview == result
    assert "tenant" in metadata.context_keys
  end

  test "supports structured parent-visible map results from subagents" do
    map_tool = find_tool(StructuredMapOrchestratorAgent, "map_result_agent")
    agent_id = "subagent-parent-map"
    request_id = "req-subagent-map-1"

    assert {:ok, %{result: result, subagent: metadata}} =
             map_tool.run(%{task: "Structured map task"}, %{
               :tenant => "structured",
               Jidoka.Subagent.server_key() => self(),
               Jidoka.Subagent.request_id_key() => request_id,
               Jidoka.Trace.agent_id_key() => agent_id
             })

    assert result == %{
             category: "research",
             confidence: 0.91,
             summary: "map:Structured map task"
           }

    assert metadata.name == "map_result_agent"
    assert metadata.mode == :ephemeral
    assert metadata.outcome == :ok
    assert metadata.result_preview =~ "map:Structured map task"
    assert "tenant" in metadata.context_keys

    assert [%{name: "map_result_agent", result_preview: preview, outcome: :ok}] =
             Jidoka.Subagent.request_calls(self(), request_id)

    assert preview =~ "map:Structured map task"

    assert {:ok, trace} = Jidoka.Trace.for_request(agent_id, request_id)
    stop_event = Enum.find(trace.events, &(&1.category == :subagent and &1.event == :stop))
    assert stop_event.metadata.result_preview =~ "map:Structured map task"
  end

  test "structured subagents still reject unsupported result shapes" do
    invalid_tool = find_tool(StructuredInvalidResultOrchestratorAgent, "list_result_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             invalid_tool.run(%{task: "Invalid structured result"}, %{})

    assert error.message == "Subagent returned an invalid result."
    assert error.details.reason == :invalid_result
    assert error.details.agent_id == "list_result_agent"
    assert error.details.cause == ["not", "supported"]
  end

  test "operation controls can interrupt subagent delegation before child execution" do
    runtime = ControlledSubagentOrchestratorAgent.runtime_module()
    agent = new_runtime_agent(runtime)
    request_id = "req-subagent-hitl-1"

    hook_context =
      %{notify_pid: self()}
      |> Jidoka.Hooks.attach_request_hooks(%{
        before_turn: [],
        after_turn: [],
        on_interrupt: [JidokaTest.NotifyDelegationInterruptHook]
      })

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "delegate",
                  request_id: request_id,
                  tool_context: hook_context
                }}
             )

    research_tool = find_tool(ControlledSubagentOrchestratorAgent, "research_agent")

    assert {:error, {:interrupt, %Jidoka.Interrupt{} = interrupt}} =
             research_tool.run(%{task: "Needs approval"}, params.tool_context)

    assert interrupt.kind == :approval
    assert interrupt.message == "Approve subagent research_agent."
    assert interrupt.data.kind == :subagent

    assert_receive {:delegation_interrupt, :approval, :subagent, :operation_control}
    refute_receive {:research_specialist_context, _forwarded_context}
    assert Jidoka.Subagent.request_calls(self(), request_id) == []
  end

  test "supports persistent peer subagents with static ids" do
    assert {:ok, pid} = ResearchSpecialist.start_link(id: "research-peer-test")
    agent_id = "subagent-parent-peer"
    request_id = "req-subagent-peer-1"

    try do
      research_tool = find_tool(PeerOrchestratorAgent, "research_agent")

      assert {:ok, %{result: "research:Investigate the bug:tenant=peer:depth=1"}} =
               research_tool.run(
                 %{task: "Investigate the bug"},
                 %{
                   :tenant => "peer",
                   Jidoka.Subagent.server_key() => self(),
                   Jidoka.Subagent.request_id_key() => request_id,
                   Jidoka.Trace.agent_id_key() => agent_id
                 }
               )

      assert Jidoka.whereis("research-peer-test") == pid

      assert [%{name: "research_agent", mode: :peer, child_id: "research-peer-test", outcome: :ok}] =
               Jidoka.Subagent.request_calls(self(), request_id)

      assert {:ok, trace} = Jidoka.Trace.for_request(agent_id, request_id)
      stop_event = Enum.find(trace.events, &(&1.category == :subagent and &1.event == :stop))
      assert stop_event.metadata.mode == :peer
      assert stop_event.metadata.child_id == "research-peer-test"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "supports persistent peer subagents with context-derived ids" do
    assert {:ok, pid} = ResearchSpecialist.start_link(id: "research-peer-ctx-test")

    try do
      research_tool = find_tool(ContextPeerOrchestratorAgent, "research_agent")

      assert {:ok, %{result: "research:Review this report:tenant=ctx:depth=1"}} =
               research_tool.run(
                 %{task: "Review this report"},
                 %{tenant: "ctx", research_peer_id: "research-peer-ctx-test"}
               )
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "resolves context-derived peer ids before applying context forwarding policy" do
    assert {:ok, pid} = ResearchSpecialist.start_link(id: "research-peer-no-forward-test")

    try do
      research_tool = find_tool(ContextPeerNoForwardOrchestratorAgent, "research_agent")

      assert {:ok, %{result: "research:Review no-forward peer:tenant=none:depth=1"}} =
               research_tool.run(
                 %{task: "Review no-forward peer"},
                 %{tenant: "hidden", research_peer_id: "research-peer-no-forward-test"}
               )
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "rejects persistent peers whose runtime module does not match the configured subagent" do
    assert {:ok, pid} = ReviewSpecialist.start_link(id: "wrong-peer-test")

    try do
      research_tool = find_tool(WrongPeerOrchestratorAgent, "research_agent")

      assert {:error, %Jidoka.Error.ExecutionError{} = error} =
               research_tool.run(%{task: "Validate peer"}, %{})

      assert error.message == "Subagent peer runtime did not match the configured agent."
      assert error.details.reason == :peer_mismatch
      assert error.details.agent_id == "research_agent"

      assert error.details.cause ==
               {:peer_mismatch, JidokaTest.ResearchSpecialist.Runtime, JidokaTest.ReviewSpecialist.Runtime}
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "missing persistent peers fail clearly" do
    research_tool = find_tool(MissingPeerOrchestratorAgent, "research_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             research_tool.run(%{task: "Find peer"}, %{})

    assert error.message == "Subagent peer could not be found."
    assert error.details.reason == :peer_not_found
    assert error.details.agent_id == "research_agent"
    assert error.details.cause == {:peer_not_found, "missing-peer-test"}
  end

  test "normalizes timeout failures and stops ephemeral children" do
    slow_tool = find_tool(TimeoutOrchestratorAgent, "slow_agent")
    agent_id = "subagent-parent-timeout"
    request_id = "req-subagent-timeout-1"

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             slow_tool.run(%{task: "Too slow"}, %{
               Jidoka.Subagent.server_key() => self(),
               Jidoka.Subagent.request_id_key() => request_id,
               Jidoka.Trace.agent_id_key() => agent_id
             })

    assert error.message == "Subagent timed out."
    assert error.details.reason == :timeout
    assert error.details.timeout == 20
    assert error.details.request_id == request_id
    assert error.details.cause == {:timeout, 20}

    assert [%{child_id: child_id, outcome: {:error, {:timeout, 20}}}] =
             Jidoka.Subagent.request_calls(self(), request_id)

    refute_agent_running(child_id)

    assert {:ok, trace} = Jidoka.Trace.for_request(agent_id, request_id)

    assert [%{event: :start}, %{event: :error, status: :failed, metadata: metadata}] =
             Enum.filter(trace.events, &(&1.category == :subagent))

    assert metadata.child_id == child_id
    assert metadata.mode == :ephemeral
    assert metadata.outcome == {:error, {:timeout, 20}}
    assert metadata.error =~ "timeout"
  end

  test "normalizes invalid child result failures" do
    invalid_tool = find_tool(InvalidResultOrchestratorAgent, "invalid_result_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             invalid_tool.run(%{task: "Invalid"}, %{})

    assert error.message == "Subagent returned an invalid result."
    assert error.details.reason == :invalid_result
    assert error.details.agent_id == "invalid_result_agent"
    assert error.details.cause == %{not: "text"}
  end

  test "normalizes raised child chat failures without crashing the caller" do
    raising_tool = find_tool(RaisingOrchestratorAgent, "raising_agent")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:raising_subagent_result, raising_tool.run(%{task: "Raise"}, %{})})
      end)

    assert_receive {:raising_subagent_result, {:error, %Jidoka.Error.ExecutionError{} = error}}
    assert error.message == "Subagent child failed."
    assert %RuntimeError{message: "raising specialist failed"} = error.details.cause
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "normalizes child interrupts" do
    interrupt_tool = find_tool(InterruptOrchestratorAgent, "interrupt_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             interrupt_tool.run(%{task: "Interrupt"}, %{})

    assert error.message == "Subagent interrupted the delegation."
    assert error.details.reason == :child_interrupt
    assert %Jidoka.Interrupt{kind: :approval, message: "Need approval"} = error.details.cause
  end

  test "invalid child interrupts are treated as invalid child results" do
    interrupt_tool = find_tool(InvalidInterruptOrchestratorAgent, "invalid_interrupt_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             interrupt_tool.run(%{task: "Invalid interrupt"}, %{})

    assert error.message == "Subagent returned an invalid result."
    assert error.details.reason == :invalid_result
    assert error.details.cause == {:interrupt, :not_an_interrupt}
  end

  test "normalizes ephemeral start failures" do
    start_failure_tool = find_tool(StartFailureOrchestratorAgent, "start_failure_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             start_failure_tool.run(%{task: "Start"}, %{})

    assert error.message == "Subagent could not be started."
    assert error.details.reason == :start_failed
    assert error.details.cause == {:start_failed, :boom}
  end

  test "normalizes ignored ephemeral starts" do
    start_ignore_tool = find_tool(StartIgnoreOrchestratorAgent, "start_ignore_agent")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             start_ignore_tool.run(%{task: "Start"}, %{})

    assert error.message == "Subagent could not be started."
    assert error.details.reason == :start_failed
    assert error.details.cause == {:start_failed, :ignore}
  end

  test "accepts supervisor-style triple start returns" do
    request_id = "req-subagent-triple-start-1"
    start_triple_tool = find_tool(StartTripleOrchestratorAgent, "start_triple_agent")

    assert {:ok, %{result: "triple:Start triple"}} =
             start_triple_tool.run(%{task: "Start triple"}, %{
               Jidoka.Subagent.server_key() => self(),
               Jidoka.Subagent.request_id_key() => request_id
             })

    assert [%{child_id: child_id, outcome: :ok}] = Jidoka.Subagent.request_calls(self(), request_id)
    refute_agent_running(child_id)
  end

  test "enforces the one-hop subagent delegation limit" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Subagent.run_subagent(
               hd(OrchestratorAgent.subagents()),
               %{task: "Nested delegation"},
               %{Jidoka.Subagent.depth_key() => 1}
             )

    assert error.message == "Subagent delegation is limited to 1 nested level."
    assert error.details.reason == :recursion_limit
    assert error.details.cause == {:recursion_limit, 1}
  end

  test "retains subagent call metadata on the parent request" do
    runtime = OrchestratorAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "delegate",
                  request_id: "req-subagent-meta-1",
                  tool_context: %{tenant: "meta"}
                }}
             )

    research_tool = find_tool(OrchestratorAgent, "research_agent")

    assert {:ok, %{result: "research:Collect notes:tenant=meta:depth=1"}} =
             research_tool.run(%{task: "Collect notes"}, params.tool_context)

    assert {:ok, updated_agent, []} =
             runtime.on_after_cmd(
               agent,
               {:ai_react_start, %{request_id: "req-subagent-meta-1"}},
               []
             )

    assert [%{name: "research_agent", mode: :ephemeral, outcome: :ok}] =
             get_in(updated_agent.state, [
               :requests,
               "req-subagent-meta-1",
               :meta,
               :jidoka_subagents,
               :calls
             ])
  end

  test "falls back to live subagent metadata when request state has not been updated yet" do
    runtime = OrchestratorAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, _agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "delegate",
                  request_id: "req-subagent-meta-live-1",
                  tool_context: %{tenant: "live"}
                }}
             )

    research_tool = find_tool(OrchestratorAgent, "research_agent")

    assert {:ok, %{result: "research:Collect notes:tenant=live:depth=1"}} =
             research_tool.run(%{task: "Collect notes"}, params.tool_context)

    assert [
             %{
               name: "research_agent",
               mode: :ephemeral,
               outcome: :ok
             }
           ] =
             Jidoka.Subagent.request_calls(self(), "req-subagent-meta-live-1")
  end

  test "retains pending metadata recorded by a process that exits before inspection" do
    request_id = "req-subagent-meta-exited-1"
    parent = self()
    research_tool = find_tool(OrchestratorAgent, "research_agent")

    pid =
      spawn(fn ->
        assert {:ok, %{result: "research:Collect from exiting process:tenant=exited:depth=1"}} =
                 research_tool.run(%{task: "Collect from exiting process"}, %{
                   Jidoka.Subagent.server_key() => parent,
                   Jidoka.Subagent.request_id_key() => request_id,
                   tenant: "exited"
                 })

        send(parent, :metadata_writer_done)
      end)

    assert_receive :metadata_writer_done
    refute Process.alive?(pid)

    assert [
             %{
               name: "research_agent",
               mode: :ephemeral,
               outcome: :ok,
               context_keys: keys
             }
           ] = Jidoka.Subagent.request_calls(self(), request_id)

    assert "tenant" in keys
  end

  test "returns recorded subagent calls in invocation order" do
    context = %{
      Jidoka.Subagent.server_key() => self(),
      Jidoka.Subagent.request_id_key() => "req-subagent-order-1",
      tenant: "ordered"
    }

    assert {:ok, "review:First delegated task"} =
             Jidoka.Subagent.run_subagent(
               Enum.at(OrchestratorAgent.subagents(), 1),
               %{task: "First delegated task"},
               context
             )

    assert {:ok, "research:Second delegated task:tenant=ordered:depth=1"} =
             Jidoka.Subagent.run_subagent(
               hd(OrchestratorAgent.subagents()),
               %{task: "Second delegated task"},
               context
             )

    assert [
             %{name: "review_specialist"},
             %{name: "research_agent"}
           ] = Jidoka.Subagent.request_calls(self(), "req-subagent-order-1")
  end

  defp refute_agent_running(id, attempts \\ 10)

  defp refute_agent_running(id, 0), do: refute(Jidoka.whereis(id))

  defp refute_agent_running(id, attempts) do
    case Jidoka.whereis(id) do
      nil ->
        :ok

      _pid ->
        Process.sleep(10)
        refute_agent_running(id, attempts - 1)
    end
  end
end
