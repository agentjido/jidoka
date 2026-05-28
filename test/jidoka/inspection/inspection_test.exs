defmodule JidokaTest.InspectionTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Request
  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent
  alias Jidoka.Compaction
  alias JidokaTest.AddNumbers

  test "inspects a compiled Jidoka agent module" do
    assert {:ok, definition} = Jidoka.inspect_agent(JidokaTest.ToolAgent)

    assert definition.kind == :agent_definition
    assert definition.module == JidokaTest.ToolAgent
    assert definition.runtime_module == JidokaTest.ToolAgent.runtime_module()
    assert definition.name == "tool_agent"
    assert definition.tool_names == ["add_numbers"]
    assert definition.plugins == []
  end

  test "inspects an imported Jidoka agent definition" do
    assert {:ok, agent} =
             Jidoka.import_agent(
               %{
                 "agent" => %{"id" => "inspect_imported"},
                 "defaults" => %{
                   "model" => "fast",
                   "instructions" => "You are concise."
                 },
                 "capabilities" => %{"tools" => ["add_numbers"]}
               },
               available_tools: [AddNumbers]
             )

    assert {:ok, definition} = Jidoka.inspect_agent(agent)

    assert definition.kind == :imported_agent_definition
    assert definition.module == nil
    assert definition.id == "inspect_imported"
    assert definition.name == "inspect_imported"
    assert definition.tool_names == ["add_numbers"]
    assert definition.runtime_module == agent.runtime_module
  end

  test "inspects a running Jidoka agent and includes the latest request summary" do
    {:ok, pid} = JidokaTest.ToolAgent.start_link(id: "inspect-running-tool-agent")

    try do
      request_id = "req-inspect-running-1"

      :sys.replace_state(pid, fn state ->
        request =
          state.agent
          |> Request.start_request(request_id, "inspect this")
          |> Request.complete_request(
            request_id,
            "42",
            meta: %{
              jidoka_debug: %{
                system_prompt: "You can use math tools.",
                tool_names: ["add_numbers"],
                message_count: 1
              }
            }
          )

        %{state | agent: request}
      end)

      assert {:ok, inspection} = Jidoka.inspect_agent(pid)

      assert inspection.kind == :running_agent
      assert inspection.runtime_module == JidokaTest.ToolAgent.runtime_module()
      assert inspection.definition.name == "tool_agent"
      assert inspection.definition.tool_names == ["add_numbers"]
      assert inspection.last_request_id == request_id
      assert inspection.last_request.input_message == "inspect this"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "inspects a request summary directly" do
    agent = new_runtime_agent(JidokaTest.ToolAgent.runtime_module())
    request_id = "req-inspect-summary-1"

    agent =
      agent
      |> Request.start_request(request_id, "original prompt")
      |> Request.complete_request(
        request_id,
        "42",
        meta: %{
          usage: %{input: 10, output: 2},
          jidoka_debug: %{
            system_prompt: "You can use math tools.",
            tool_names: ["add_numbers"],
            message_count: 1
          }
        }
      )

    assert {:ok, summary} = Jidoka.inspect_request(agent, request_id)
    assert summary.request_id == request_id
    assert summary.system_prompt == "You can use math tools."
    assert summary.tool_names == ["add_numbers"]
    assert summary.usage == %{input: 10, output: 2, total: nil, cost: nil}
  end

  test "verifies public inspection surfaces for a running debug target" do
    agent_id = "inspect-debug-surfaces-#{System.unique_integer([:positive])}"
    request_id = "req-inspect-debug-surfaces"

    {:ok, pid} = JidokaTest.ManualCompactionAgent.start_link(id: agent_id)

    try do
      :sys.replace_state(pid, fn state ->
        agent =
          state.agent
          |> Request.start_request(request_id, "inspect every surface")
          |> Request.complete_request(
            request_id,
            "inspection complete",
            meta: %{
              usage: %{input: 4, output: 2},
              jidoka_debug: %{
                system_prompt: "You have manual compaction.",
                tool_names: [],
                message_count: 4
              }
            }
          )
          |> put_thread([
            ai_message(:user, "old inspection prompt", request_id: "req-old"),
            ai_message(:assistant, "old inspection answer", request_id: "req-old"),
            ai_message(:user, "inspect every surface", request_id: request_id),
            ai_message(:assistant, "inspection complete", request_id: request_id)
          ])

        Jido.AgentServer.State.update_agent(state, agent)
      end)

      :telemetry.execute(
        [:jido, :ai, :request, :start],
        %{},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      :telemetry.execute(
        [:jido, :ai, :request, :complete],
        %{duration_ms: 12},
        %{agent_id: agent_id, request_id: request_id, run_id: request_id}
      )

      assert {:ok, %Compaction{status: :summarized, summary: "inspection summary"}} =
               Jidoka.compact(pid, summarizer: fn _input -> {:ok, "inspection summary"} end)

      assert {:ok, agent_summary} = Jidoka.inspect_agent(pid)
      assert agent_summary.kind == :running_agent
      assert agent_summary.id == agent_id
      assert agent_summary.last_request_id == request_id
      assert agent_summary.last_request.system_prompt == "You have manual compaction."

      assert {:ok, request_summary} = Jidoka.inspect_request(pid, request_id)
      assert request_summary.request_id == request_id
      assert request_summary.status == :completed
      assert request_summary.usage == %{input: 4, output: 2, total: nil, cost: nil}

      assert {:ok, trace} = Jidoka.inspect_trace(pid, request_id)
      assert trace.agent_id == agent_id
      assert trace.status == :completed

      assert {:ok, %Compaction{} = compaction} = Jidoka.inspect_compaction(pid)
      assert compaction.summary_preview == "inspection summary"

      assert {:ok, snapshot} = Jidoka.Agent.View.snapshot(pid)
      assert snapshot.kind == :agent_view
      assert snapshot.agent_id == agent_id

      assert Enum.map(snapshot.visible_messages, & &1.content) == [
               "old inspection prompt",
               "old inspection answer",
               "inspect every surface",
               "inspection complete"
             ]
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  defp put_thread(agent, entries) do
    ThreadAgent.put(agent, Thread.new(id: "thread-inspection") |> Thread.append(entries))
  end

  defp ai_message(role, content, attrs) do
    payload =
      attrs
      |> Map.new()
      |> Map.merge(%{role: role, content: content, context_ref: Keyword.get(attrs, :context_ref, "default")})

    %{
      kind: :ai_message,
      payload: payload,
      refs: %{request_id: Map.get(payload, :request_id)}
    }
  end
end
