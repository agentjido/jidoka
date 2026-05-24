defmodule JidokaTest.TraceTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Trace

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

    memory_request_id = unique_id("req-memory")
    memory_agent = JidokaTest.MemoryAgent.runtime_module().new(id: agent_id)

    assert {:ok, _agent, {:ai_react_start, _params}} =
             Jidoka.Memory.on_before_cmd(
               memory_agent,
               {:ai_react_start,
                %{
                  query: "remember this",
                  request_id: memory_request_id,
                  tool_context: %{session: unique_id("session")}
                }},
               JidokaTest.MemoryAgent.memory(),
               JidokaTest.MemoryAgent.context()
             )

    assert {:ok, memory_trace} = Trace.for_request(agent_id, memory_request_id)
    assert Enum.any?(memory_trace.events, &(&1.category == :memory and &1.event == :retrieve))
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
      tenant: "acme"
    }
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
end
