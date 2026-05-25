defmodule JidokaTest.TraceTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Trace

  @trace_session_id "trace-session"
  @trace_conversation_id "trace-conversation"
  @trace_context_ref "trace-context"

  defmodule InterruptInputGuardrail do
    use Jidoka.Guardrail, name: "trace_interrupt_input"

    @impl true
    def call(%Jidoka.Guardrails.Input{}) do
      {:interrupt, %{kind: :approval, message: "Review this request.", data: %{}}}
    end
  end

  test "normalizes Jido.AI telemetry into a bounded structured trace" do
    agent_id = unique_id("trace-agent")
    request_id = unique_id("req")
    run_id = unique_id("run")

    :telemetry.execute(
      [:jido, :ai, :request, :start],
      %{duration_ms: 0},
      %{
        agent_id: agent_id,
        request_id: request_id,
        run_id: run_id,
        jido_trace_id: "trace-#{request_id}",
        jido_span_id: "span-root",
        query: "do not store this prompt",
        api_key: "secret"
      }
    )

    :telemetry.execute(
      [:jido, :ai, :llm, :complete],
      %{duration_ms: 12, input_tokens: 5, output_tokens: 7},
      %{
        agent_id: agent_id,
        request_id: request_id,
        run_id: run_id,
        model: "anthropic:test",
        llm_call_id: "llm-1"
      }
    )

    :telemetry.execute(
      [:jido, :ai, :tool, :complete],
      %{duration_ms: 3},
      %{
        agent_id: agent_id,
        request_id: request_id,
        run_id: run_id,
        tool_name: "add_numbers",
        tool_call_id: "tool-1"
      }
    )

    :telemetry.execute(
      [:jido, :ai, :request, :complete],
      %{duration_ms: 20},
      %{agent_id: agent_id, request_id: request_id, run_id: run_id}
    )

    assert {:ok, trace} = Trace.for_request(agent_id, request_id)
    assert trace.agent_id == agent_id
    assert trace.request_id == request_id
    assert trace.run_id == run_id
    assert trace.status == :completed
    assert Enum.map(trace.events, & &1.category) == [:request, :model, :tool, :request]

    first = hd(trace.events)
    assert first.metadata.query == "[OMITTED]"
    assert first.metadata.api_key == "[REDACTED]"

    assert {:ok, spans} = Trace.spans(trace)
    assert Enum.any?(spans, &(&1.category == :tool and &1.name == "add_numbers"))
  end

  test "normalizes foundation request model and action telemetry into one trace" do
    agent_id = unique_id("trace-foundation-agent")
    request_id = unique_id("req-foundation")
    run_id = unique_id("run-foundation")
    trace_id = unique_id("trace-foundation")
    span_id = unique_id("span-foundation")

    common = %{
      agent_id: agent_id,
      request_id: request_id,
      run_id: run_id,
      jido_trace_id: trace_id,
      jido_span_id: span_id
    }

    obs_cfg = %{emit_telemetry?: true, emit_llm_deltas?: false}

    Jido.AI.Observe.emit(obs_cfg, Jido.AI.Observe.request(:start), %{duration_ms: 0}, common)

    Jido.AI.Observe.emit(
      obs_cfg,
      Jido.AI.Observe.llm(:start),
      %{duration_ms: 0},
      Map.merge(common, %{model: "anthropic:test", llm_call_id: "llm-1"})
    )

    Jido.AI.Observe.emit(
      obs_cfg,
      Jido.AI.Observe.llm(:complete),
      %{duration_ms: 12, input_tokens: 5, output_tokens: 7, total_tokens: 12},
      Map.merge(common, %{model: "anthropic:test", llm_call_id: "llm-1"})
    )

    :telemetry.execute(
      [:jido, :action, :start],
      %{system_time: System.system_time()},
      %{action: JidokaTest.AddNumbers, jido: common}
    )

    :telemetry.execute(
      [:jido, :action, :stop],
      %{duration: 2_000_000},
      %{action: JidokaTest.AddNumbers, outcome: :ok, jido: common}
    )

    Jido.AI.Observe.emit(obs_cfg, Jido.AI.Observe.request(:complete), %{duration_ms: 20}, common)

    assert {:ok, trace} = Trace.for_request(agent_id, request_id)

    assert Enum.map(trace.events, &{&1.source, &1.category, &1.event, &1.status}) == [
             {:jido_ai, :request, :start, :running},
             {:jido_ai, :model, :start, :running},
             {:jido_ai, :model, :complete, :completed},
             {:jido_action, :action, :start, :running},
             {:jido_action, :action, :stop, :completed},
             {:jido_ai, :request, :complete, :completed}
           ]

    assert trace.status == :completed
    assert trace.summary.model_events == 2
    assert trace.summary.action_events == 2

    action_event = Enum.find(trace.events, &(&1.category == :action and &1.event == :stop))
    assert action_event.request_id == request_id
    assert action_event.run_id == run_id
    assert action_event.trace_id == trace_id
    assert action_event.span_id == span_id
    assert action_event.name =~ "JidokaTest.AddNumbers"
  end

  test "normalizes rejected request telemetry as a failed terminal event" do
    agent_id = unique_id("trace-rejected-agent")
    request_id = unique_id("req-rejected")

    Jido.AI.Observe.emit(
      %{emit_telemetry?: true},
      Jido.AI.Observe.request(:rejected),
      %{duration_ms: 1},
      %{agent_id: agent_id, request_id: request_id, run_id: request_id, error_type: :validation}
    )

    assert {:ok, trace} = Trace.for_request(agent_id, request_id)
    assert trace.status == :failed
    assert [%{category: :request, event: :rejected, status: :failed}] = trace.events
  end

  test "keeps correlation fields stable across trace event surfaces" do
    agent_id = unique_id("trace-correlation-agent")
    request_id = unique_id("req-correlation")
    run_id = unique_id("run-correlation")
    trace_id = unique_id("trace-correlation")
    span_id = unique_id("span-correlation")
    parent_span_id = unique_id("span-parent")
    conversation_id = unique_id("conversation")
    session_id = unique_id("session")

    common = %{
      agent_id: agent_id,
      request_id: request_id,
      run_id: run_id,
      trace_id: trace_id,
      span_id: span_id,
      parent_span_id: parent_span_id,
      conversation_id: conversation_id,
      session_id: session_id
    }

    :telemetry.execute(
      [:jido, :ai, :request, :start],
      %{},
      Map.merge(common, %{query: "chat prompt"})
    )

    :telemetry.execute(
      [:jido, :ai, :tool, :complete],
      %{duration_ms: 4},
      Map.merge(common, %{tool_name: "lookup_ticket", tool_call_id: "tool-call-1"})
    )

    [
      {:action, %{event: :complete, action: "lookup_ticket"}},
      {:control, %{event: :allow, control: "limit_delegation"}},
      {:workflow, %{event: :start, workflow: "ticket_workflow"}},
      {:subagent, %{event: :stop, subagent: "research_agent", child_request_id: "child-req-1"}},
      {:handoff, %{event: :stop, handoff: "billing_agent"}},
      {:schedule, %{event: :start, schedule_id: "daily_digest"}},
      {:memory, %{event: :retrieve, namespace: "agent:#{agent_id}"}},
      {:compaction, %{event: :summarized, compaction: "summary"}}
    ]
    |> Enum.each(fn {category, metadata} ->
      Jidoka.Trace.emit(category, Map.merge(common, metadata), %{duration_ms: 1})
    end)

    assert {:ok, trace} = Trace.for_request(agent_id, request_id)

    categories = Enum.map(trace.events, & &1.category)

    for category <- [
          :request,
          :tool,
          :action,
          :control,
          :workflow,
          :subagent,
          :handoff,
          :schedule,
          :memory,
          :compaction
        ] do
      assert category in categories
    end

    for event <- trace.events do
      assert event.request_id == request_id
      assert event.run_id == run_id
      assert event.trace_id == trace_id
      assert event.span_id == span_id
      assert event.parent_span_id == parent_span_id
      assert event.metadata.agent_id == agent_id
      assert event.metadata.conversation_id == conversation_id
      assert event.metadata.session_id == session_id
    end

    assert trace.summary.action_events == 1
    assert trace.summary.control_events == 1
    assert trace.summary.tool_events == 1
    assert trace.summary.workflow_events == 1
    assert trace.summary.subagent_events == 1
    assert trace.summary.handoff_events == 1
    assert trace.summary.schedule_events == 1
    assert trace.summary.memory_events == 1
    assert trace.summary.compaction_events == 1
  end

  test "lifts session correlation refs into emitted trace metadata" do
    session =
      Jidoka.Session.new!(
        agent: JidokaTest.ToolAgent,
        id: "Trace Session 42",
        conversation_id: "Support Conversation 42",
        context_ref: "support-lane"
      )

    request_id = unique_id("req-session-correlation")
    run_id = unique_id("run-session-correlation")
    trace_id = unique_id("trace-session-correlation")
    span_id = unique_id("span-session-correlation")
    parent_span_id = unique_id("span-parent-session-correlation")

    opts =
      Jidoka.Session.chat_opts(session,
        request_id: request_id,
        extra_refs: %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: parent_span_id
        }
      )

    Jidoka.Trace.emit(:control, %{
      event: :allow,
      control: "session_control",
      agent_id: session.agent_id,
      request_id: request_id,
      run_id: run_id,
      extra_refs: Keyword.fetch!(opts, :extra_refs)
    })

    assert {:ok, trace} = Trace.for_request(session.agent_id, request_id)
    assert [event] = trace.events
    assert event.request_id == request_id
    assert event.run_id == run_id
    assert event.trace_id == trace_id
    assert event.span_id == span_id
    assert event.parent_span_id == parent_span_id
    assert event.metadata.session_id == session.id
    assert event.metadata.conversation_id == session.conversation_id
    assert event.metadata.context_ref == session.context_ref
    assert event.metadata.extra_refs.session_id == session.id
  end

  test "sanitizes emitted Jidoka telemetry metadata and measurements" do
    agent_id = unique_id("trace-redaction-agent")
    request_id = unique_id("req-redaction")
    run_id = unique_id("run-redaction")
    handler_id = :"jidoka-trace-redaction-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:jidoka, :control, :event],
        &__MODULE__.handle_trace_redaction_event/4,
        parent
      )

    try do
      Jidoka.Trace.emit(
        :control,
        %{
          event: :allow,
          control: "redact_secret",
          agent_id: agent_id,
          request_id: request_id,
          run_id: run_id,
          query: "do not export this prompt",
          note: "api_key=super-secret-key",
          nested: %{api_key: "nested-secret"},
          extra_refs: %{session_id: "session-redaction", token: "raw-token"}
        },
        %{
          duration_ms: 1,
          raw_response: "provider-secret-response",
          detail: "password=measurement-secret"
        }
      )

      assert_receive {:jidoka_trace_event, [:jidoka, :control, :event], measurements, metadata}

      assert metadata.query == "[OMITTED]"
      assert metadata.note == "api_key=[REDACTED]"
      assert metadata.nested.api_key == "[REDACTED]"
      assert metadata.extra_refs.token == "[REDACTED]"
      assert metadata.session_id == "session-redaction"
      assert measurements.raw_response == "[OMITTED]"
      assert measurements.detail == "password=[REDACTED]"

      refute inspect(metadata) =~ "super-secret-key"
      refute inspect(metadata) =~ "nested-secret"
      refute inspect(metadata) =~ "raw-token"
      refute inspect(measurements) =~ "provider-secret-response"
      refute inspect(measurements) =~ "measurement-secret"

      assert {:ok, trace} = Trace.for_request(agent_id, request_id)
      assert [event] = trace.events
      assert event.metadata.query == "[OMITTED]"
      assert event.metadata.note == "api_key=[REDACTED]"
      assert event.metadata.nested.api_key == "[REDACTED]"
      assert event.metadata.extra_refs.token == "[REDACTED]"
      assert event.measurements.raw_response == "[OMITTED]"
      assert event.measurements.detail == "password=[REDACTED]"
    after
      :telemetry.detach(handler_id)
    end
  end

  test "returns latest and list traces for an agent id" do
    agent_id = unique_id("trace-list-agent")
    request_id = unique_id("req")

    :telemetry.execute(
      [:jido, :ai, :request, :start],
      %{},
      %{agent_id: agent_id, request_id: request_id, run_id: request_id}
    )

    assert {:ok, trace} = Trace.latest(agent_id)
    assert trace.request_id == request_id

    assert {:ok, traces} = Trace.list(agent_id)
    assert Enum.any?(traces, &(&1.request_id == request_id))
  end

  test "enforces bounded trace retention per unique agent" do
    agent_id = unique_id("trace-retention-agent")

    for index <- 1..105 do
      request_id = "#{agent_id}-req-#{index}"

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )
    end

    assert {:ok, traces} = Trace.list(agent_id)
    assert length(traces) <= 100
    refute Enum.any?(traces, &(&1.request_id == "#{agent_id}-req-1"))
  end

  test "records Jidoka workflow, subagent, handoff, guardrail, and memory events without a provider" do
    agent_id = unique_id("trace-jidoka-agent")

    workflow_request_id = unique_id("req-workflow")
    workflow_tool = find_tool(JidokaTest.WorkflowCapability.MathAgent, "run_math")

    assert {:ok, _workflow_result} =
             workflow_tool.run(
               %{value: 3},
               trace_context(agent_id, workflow_request_id)
             )

    assert {:ok, workflow_trace} = Trace.for_request(agent_id, workflow_request_id)
    assert Enum.any?(workflow_trace.events, &(&1.category == :workflow and &1.event == :start))
    assert Enum.any?(workflow_trace.events, &(&1.category == :workflow and &1.event == :step))
    assert Enum.any?(workflow_trace.events, &(&1.category == :workflow and &1.event == :stop))
    assert_lifecycle_refs(workflow_trace, :workflow)

    subagent_request_id = unique_id("req-subagent")
    subagent_tool = find_tool(JidokaTest.OrchestratorAgent, "research_agent")

    assert {:ok, _subagent_result} =
             subagent_tool.run(
               %{task: "summarize tracing"},
               trace_context(agent_id, subagent_request_id)
             )

    assert {:ok, subagent_trace} = Trace.for_request(agent_id, subagent_request_id)
    assert Enum.any?(subagent_trace.events, &(&1.category == :subagent and &1.event == :start))
    assert Enum.any?(subagent_trace.events, &(&1.category == :subagent and &1.event == :stop))
    assert_lifecycle_refs(subagent_trace, :subagent)

    handoff_request_id = unique_id("req-handoff")
    conversation_id = unique_id("trace-conversation")
    handoff_tool = find_tool(JidokaTest.HandoffRouterAgent, "billing_specialist")

    try do
      assert {:error, {:handoff, %Jidoka.Handoff{}}} =
               handoff_tool.run(
                 %{message: "Please take over.", summary: "Billing issue.", reason: "billing"},
                 trace_context(agent_id, handoff_request_id)
                 |> Map.put(Jidoka.Handoff.context_key(), conversation_id)
                 |> Map.put(Jidoka.Handoff.from_agent_key(), JidokaTest.HandoffRouterAgent.id())
               )

      assert {:ok, handoff_trace} = Trace.for_request(agent_id, handoff_request_id)
      assert Enum.any?(handoff_trace.events, &(&1.category == :handoff and &1.event == :start))
      assert Enum.any?(handoff_trace.events, &(&1.category == :handoff and &1.event == :stop))
    after
      case Jidoka.handoff_owner(conversation_id) do
        %{agent_id: handoff_agent_id} -> reset_agent(handoff_agent_id)
        _ -> :ok
      end

      Jidoka.reset_handoff(conversation_id)
    end

    guardrail_request_id = unique_id("req-guardrail")
    guardrail_agent = new_runtime_agent(JidokaTest.ToolAgent.runtime_module())

    assert {:ok, _agent, {:ai_react_request_error, _params}} =
             Jidoka.Guardrails.on_before_cmd(
               guardrail_agent,
               {:ai_react_start,
                %{
                  query: "needs approval",
                  request_id: guardrail_request_id,
                  tool_context: trace_context(agent_id, guardrail_request_id)
                }},
               %{input: [InterruptInputGuardrail], output: [], tool: []}
             )

    assert {:ok, guardrail_trace} = Trace.for_request(agent_id, guardrail_request_id)
    assert Enum.any?(guardrail_trace.events, &(&1.category == :guardrail and &1.event == :interrupt))
    assert_lifecycle_refs(guardrail_trace, :guardrail)

    memory_request_id = unique_id("req-memory")
    memory_agent = JidokaTest.MemoryAgent.runtime_module().new(id: agent_id)

    assert {:ok, _agent, {:ai_react_start, _params}} =
             Jidoka.Memory.on_before_cmd(
               memory_agent,
               {:ai_react_start,
                %{
                  query: "remember this",
                  request_id: memory_request_id,
                  tool_context: %{
                    session: @trace_session_id,
                    conversation_id: @trace_conversation_id,
                    context_ref: @trace_context_ref
                  }
                }},
               JidokaTest.MemoryAgent.memory(),
               JidokaTest.MemoryAgent.context()
             )

    assert {:ok, memory_trace} = Trace.for_request(agent_id, memory_request_id)
    assert Enum.any?(memory_trace.events, &(&1.category == :memory and &1.event == :retrieve))
    assert_lifecycle_refs(memory_trace, :memory)
  end

  test "records credential references without raw secret values" do
    request_id = unique_id("req-credential-trace")
    agent = new_runtime_agent(JidokaTest.GuardrailedAgent.runtime_module())

    credential =
      Jidoka.Credential.new!(
        provider: "github",
        account: "acct_123",
        tenant: "acme",
        scopes: ["repo"],
        lease_id: "lease_123",
        risk: :high,
        confirmation_required: true,
        audit_metadata: %{api_key: "raw-secret", request_id: request_id}
      )

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Guardrails.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "call a credentialed tool",
                  request_id: request_id,
                  tool_context: %{credential_ref: credential}
                }},
               %{input: [], output: [], tool: []}
             )

    callback = Map.fetch!(params.tool_context, :__tool_guardrail_callback__)

    assert :ok =
             callback.(%{
               tool_name: "github_create_issue",
               tool_call_id: "tc-credential-trace",
               arguments: %{title: "Hello"},
               context: params.tool_context
             })

    assert {:ok, trace} = Trace.for_request(agent.id, request_id)

    event = Enum.find(trace.events, &(&1.category == :credential and &1.event == :referenced))

    assert event.metadata.credentials == [
             %{
               provider: "github",
               account: "acct_123",
               tenant: "acme",
               scopes: ["repo"],
               lease_id: "lease_123",
               risk: :high,
               confirmation_required: true,
               audit_metadata: %{api_key: "[REDACTED]", request_id: request_id}
             }
           ]

    refute inspect(event.metadata) =~ "raw-secret"
  end

  defp trace_context(agent_id, request_id) do
    %{
      Jidoka.Subagent.server_key() => self(),
      Jidoka.Subagent.request_id_key() => request_id,
      Jidoka.Handoff.server_key() => self(),
      Jidoka.Handoff.request_id_key() => request_id,
      Jidoka.Trace.agent_id_key() => agent_id,
      session: @trace_session_id,
      conversation_id: @trace_conversation_id,
      context_ref: @trace_context_ref,
      tenant: "acme"
    }
  end

  defp assert_lifecycle_refs(trace, category) do
    events = Enum.filter(trace.events, &(&1.category == category))
    assert events != []

    for event <- events do
      assert event.metadata.session_id == @trace_session_id
      assert event.metadata.conversation_id == @trace_conversation_id
      assert event.metadata.context_ref == @trace_context_ref
    end
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp reset_agent(agent_id) do
    case Jidoka.whereis(agent_id) do
      nil -> :ok
      pid -> Jidoka.stop_agent(pid)
    end
  end

  def handle_trace_redaction_event(event_name, measurements, metadata, parent) do
    send(parent, {:jidoka_trace_event, event_name, measurements, metadata})
  end
end
