defmodule JidokaTest.KinoTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Request

  require Logger

  test "trace returns the wrapped result without Kino loaded" do
    result =
      Jidoka.Kino.trace("smoke", fn ->
        Logger.notice("Executing Jido.Actions.Control.Noop with params: %{query: \"hello\"}")
        :ok
      end)

    assert result == :ok
  end

  test "load_provider_env mirrors Livebook secret names" do
    previous_anthropic = System.get_env("ANTHROPIC_API_KEY")
    previous_livebook = System.get_env("LB_ANTHROPIC_API_KEY")

    System.delete_env("ANTHROPIC_API_KEY")
    System.put_env("LB_ANTHROPIC_API_KEY", "livebook-secret")

    try do
      assert Jidoka.Kino.load_provider_env() == {:ok, "LB_ANTHROPIC_API_KEY"}
      assert System.get_env("ANTHROPIC_API_KEY") == "livebook-secret"
    after
      restore_env("ANTHROPIC_API_KEY", previous_anthropic)
      restore_env("LB_ANTHROPIC_API_KEY", previous_livebook)
    end
  end

  test "setup_notebook returns setup status and mirrors Livebook secrets" do
    previous_anthropic = System.get_env("ANTHROPIC_API_KEY")
    previous_livebook = System.get_env("LB_ANTHROPIC_API_KEY")

    System.delete_env("ANTHROPIC_API_KEY")
    System.put_env("LB_ANTHROPIC_API_KEY", "livebook-secret")

    try do
      setup = Jidoka.Kino.setup_notebook(render?: false)

      assert setup.live_provider?
      assert setup.secret_source == :livebook_secret
      assert setup.model_alias == :fast
      assert setup.model == "anthropic:claude-haiku-4-5"
      assert System.get_env("ANTHROPIC_API_KEY") == "livebook-secret"
    after
      restore_env("ANTHROPIC_API_KEY", previous_anthropic)
      restore_env("LB_ANTHROPIC_API_KEY", previous_livebook)
    end
  end

  test "setup_notebook reports missing provider credentials" do
    previous_anthropic = System.get_env("ANTHROPIC_API_KEY")
    previous_livebook = System.get_env("LB_ANTHROPIC_API_KEY")

    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("LB_ANTHROPIC_API_KEY")

    try do
      setup = Jidoka.Kino.setup_notebook(render?: false)

      refute setup.live_provider?
      assert setup.secret_source == nil
      assert setup.provider == :anthropic
    after
      restore_env("ANTHROPIC_API_KEY", previous_anthropic)
      restore_env("LB_ANTHROPIC_API_KEY", previous_livebook)
    end
  end

  test "start_or_reuse starts once and reuses a registered agent" do
    id = "kino-reuse-#{System.unique_integer([:positive])}"
    test_pid = self()

    try do
      assert {:ok, pid} =
               Jidoka.Kino.start_or_reuse(id, fn ->
                 send(test_pid, :started)
                 JidokaTest.ChatAgent.start_link(id: id)
               end)

      assert_receive :started

      assert {:ok, ^pid} =
               Jidoka.Kino.start_or_reuse(id, fn ->
                 flunk("existing agent should be reused")
               end)
    after
      case Jidoka.whereis(id) do
        nil -> :ok
        pid -> Jidoka.stop_agent(pid)
      end
    end
  end

  test "chat returns a missing provider error before calling the provider" do
    previous_anthropic = System.get_env("ANTHROPIC_API_KEY")
    previous_livebook = System.get_env("LB_ANTHROPIC_API_KEY")

    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("LB_ANTHROPIC_API_KEY")

    try do
      result =
        Jidoka.Kino.chat("missing provider", fn ->
          flunk("chat function should not run without provider configuration")
        end)

      assert {:error, message} = result
      assert message =~ "ANTHROPIC_API_KEY"
    after
      restore_env("ANTHROPIC_API_KEY", previous_anthropic)
      restore_env("LB_ANTHROPIC_API_KEY", previous_livebook)
    end
  end

  test "format_chat_result presents handoffs as notebook-friendly summaries" do
    handoff =
      Jidoka.Handoff.new(
        id: "handoff-1",
        conversation_id: "conversation-1",
        from_agent: "router",
        to_agent: JidokaTest.ChatAgent,
        to_agent_id: "billing-agent",
        name: "billing_agent",
        message: "Billing should own the next turn.",
        summary: "Invoice dispute.",
        reason: "billing",
        context: %{tenant: "acme"}
      )

    assert {:handoff, summary} = Jidoka.Kino.format_chat_result({:handoff, handoff})
    assert summary.to_agent_id == "billing-agent"
    assert summary.context_keys == ["tenant"]

    assert {:handoff, nested_summary} = Jidoka.Kino.format_chat_result({:error, {:handoff, handoff}})
    assert nested_summary.name == "billing_agent"
  end

  test "format_chat_result presents interrupts as notebook-friendly summaries" do
    interrupt =
      Jidoka.Interrupt.new(
        id: "interrupt-1",
        kind: :approval,
        message: "Approve the large calculation.",
        data: %{tool: "add_numbers"}
      )

    assert {:interrupt, summary} = Jidoka.Kino.format_chat_result({:interrupt, interrupt})
    assert summary.kind == :approval
    assert summary.data_keys == ["tool"]

    assert {:interrupt, nested_summary} = Jidoka.Kino.format_chat_result({:error, {:interrupt, interrupt}})
    assert nested_summary.message == "Approve the large calculation."
  end

  test "debug_agent renders and returns an inspection summary without Kino loaded" do
    assert {:ok, inspection} = Jidoka.Kino.debug_agent(JidokaTest.ToolAgent)

    assert inspection.kind == :agent_definition
    assert inspection.tool_names == ["add_numbers"]
  end

  test "debug_request renders a request summary without Kino loaded" do
    summary = %{
      request_id: "req-kino-debug",
      status: :failed,
      model: {:anthropic, model: "claude-test"},
      input_message: String.duplicate("summarize ", 80),
      user_message: "summarize the ticket",
      system_prompt: "Answer clearly.",
      prompt_preview: %{
        system_prompt: "Answer clearly.",
        user_message: "summarize the ticket",
        message_count: 2,
        tool_names: ["lookup_ticket"]
      },
      tool_names: ["lookup_ticket"],
      mcp_tools: [],
      context_preview: ["tenant=\"demo\"", "api_key=\"[REDACTED]\""],
      memory: %{retrieved: 2},
      compaction: %{status: :summarized, retained_message_count: 12},
      subagents: [%{name: "researcher", status: :completed}],
      workflows: [],
      handoffs: [],
      interrupt: nil,
      error: Jidoka.Error.execution_error("Provider failed.", phase: :model, details: %{api_key: "secret"}),
      usage: %{input: 10, output: 5},
      duration_ms: 42,
      message_count: 2
    }

    assert {:ok, ^summary} = Jidoka.Kino.debug_request(summary)
  end

  test "debug_request inspects the latest running request without Kino loaded" do
    {:ok, pid} = JidokaTest.ToolAgent.start_link(id: "kino-debug-request")

    try do
      request_id = "req-kino-debug-live"

      :sys.replace_state(pid, fn state ->
        %{state | agent: Request.start_request(state.agent, request_id, "live kino prompt")}
      end)

      assert {:ok, summary} = Jidoka.Kino.debug_request(pid)
      assert summary.request_id == request_id
      assert summary.status == :pending
      assert summary.prompt_preview.user_message == "live kino prompt"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "agent_diagram renders and returns Mermaid markdown without Kino loaded" do
    assert {:ok, markdown} = Jidoka.Kino.agent_diagram(JidokaTest.ToolAgent)

    assert markdown =~ "flowchart LR"
    assert markdown =~ "tool_agent"
    assert markdown =~ "add_numbers"
  end

  test "agent_diagram escapes inspected quoted values for Mermaid labels" do
    inspection = %{
      kind: :agent_definition,
      id: "quoted_agent",
      model: "anthropic:claude-haiku-4-5",
      context: %{tenant: "acme"},
      mcp_tools: [%{prefix: "ks_fs_", endpoint: :ks_livebook_mcp}],
      tool_names: ["ks_show_context"]
    }

    assert {:ok, markdown} = Jidoka.Kino.agent_diagram(inspection)

    assert markdown =~ "quoted_agent"
    assert markdown =~ "ks_fs_"
    assert markdown =~ ~s(Agent["Agent\\nquoted_agent"])
    refute markdown =~ ~s(\\")
    assert markdown =~ "%{prefix: 'ks_fs_'"
  end

  test "context renders public and internal runtime keys without Kino loaded" do
    assert :ok =
             Jidoka.Kino.context("runtime context", %{
               Jidoka.Subagent.request_id_key() => "req-1",
               "__tool_guardrail_callback__" => :callback,
               tenant: "acme"
             })
  end

  test "structured trace helpers render without Kino loaded" do
    trace = %Jidoka.Trace{
      agent_id: "trace-agent",
      request_id: "req-trace",
      run_id: "run-trace",
      trace_id: "trace-1",
      status: :completed,
      events: [
        %Jidoka.Trace.Event{
          seq: 1,
          at_ms: 1_775_000_000_000,
          source: :jido_ai,
          category: :request,
          event: :start,
          name: "trace-agent",
          status: :running,
          request_id: "req-trace",
          run_id: "run-trace",
          trace_id: "trace-1",
          measurements: %{},
          metadata: %{agent_id: "trace-agent", request_id: "req-trace"}
        },
        %Jidoka.Trace.Event{
          seq: 2,
          at_ms: 1_775_000_000_010,
          source: :jidoka,
          category: :workflow,
          event: :stop,
          name: "quoted \"workflow\"",
          status: :completed,
          duration_ms: 10,
          request_id: "req-trace",
          run_id: "run-trace",
          trace_id: "trace-1",
          measurements: %{duration_ms: 10},
          metadata: %{workflow: "quoted \"workflow\"", request_id: "req-trace"}
        }
      ]
    }

    assert {:ok, ^trace} = Jidoka.Kino.timeline(trace)
    assert {:ok, ^trace} = Jidoka.Kino.trace_table(trace)
    assert {:ok, markdown} = Jidoka.Kino.call_graph(trace)

    assert markdown =~ "flowchart TD"
    assert markdown =~ "quoted 'workflow'"
    refute markdown =~ ~s(\\")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
