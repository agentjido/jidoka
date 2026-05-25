defmodule JidokaTest.DebugSummaryTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Request

  test "summarizes a completed request from Jidoka request metadata" do
    agent = new_runtime_agent(JidokaTest.ToolAgent.runtime_module())
    request_id = "req-debug-summary-1"

    agent =
      agent
      |> Request.start_request(request_id, "original prompt")
      |> Request.complete_request(
        request_id,
        "42",
        meta: %{
          usage: %{input: 123, output: 45, total_cost: 0.00123},
          jidoka_hooks: %{
            message: "Use the add_numbers tool to add 17 and 25. Reply with only the sum.",
            context: %{
              Jidoka.Subagent.request_id_key() => "internal",
              api_key: "raw-secret",
              session: "cli",
              tenant: "demo"
            }
          },
          jidoka_memory: %{
            namespace: "agent:demo",
            records: [%{id: 1}, %{id: 2}],
            config: %{inject: :instructions},
            captured?: true
          },
          jidoka_debug: %{
            system_prompt: "You are a concise assistant. Reply with only the final answer.",
            tool_names: ["add_numbers"],
            message_count: 2
          },
          jidoka_subagents: %{
            calls: [
              %{
                name: "research_agent",
                mode: :ephemeral,
                child_id: "jidoka-subagent-1",
                duration_ms: 123,
                task_preview: "Explain vector databases",
                child_result_meta: %{status: :completed}
              }
            ]
          }
        }
      )

    {:ok, summary} = Jidoka.Debug.request_summary(agent, request_id)

    assert summary.request_id == request_id
    assert summary.status == :completed
    assert summary.model == agent.state.model
    assert summary.input_message == "original prompt"

    assert summary.user_message ==
             "Use the add_numbers tool to add 17 and 25. Reply with only the sum."

    assert summary.system_prompt ==
             "You are a concise assistant. Reply with only the final answer."

    assert summary.prompt_preview == %{
             system_prompt: "You are a concise assistant. Reply with only the final answer.",
             user_message: "Use the add_numbers tool to add 17 and 25. Reply with only the sum.",
             message_count: 2,
             tool_names: ["add_numbers"]
           }

    assert summary.tool_names == ["add_numbers"]
    assert summary.context_preview == ["api_key=\"[REDACTED]\"", "session=\"cli\"", "tenant=\"demo\""]
    refute inspect(summary.context_preview) =~ "raw-secret"
    assert summary.message_count == 2

    assert summary.memory == %{
             namespace: "agent:demo",
             retrieved: 2,
             inject: :instructions,
             captured: true
           }

    assert summary.subagents == [
             %{
               name: "research_agent",
               mode: :ephemeral,
               child_id: "jidoka-subagent-1",
               duration_ms: 123,
               task_preview: "Explain vector databases",
               child_result_meta: %{status: :completed}
             }
           ]

    assert summary.usage == %{input: 123, output: 45, total: nil, cost: 0.00123}
    assert is_integer(summary.duration_ms)
  end

  test "merges pending prompt previews for a live request" do
    {:ok, pid} = JidokaTest.ToolAgent.start_link(id: "debug-summary-live")

    try do
      request_id = "req-debug-summary-live-1"

      :sys.replace_state(pid, fn state ->
        %{state | agent: Request.start_request(state.agent, request_id, "live prompt")}
      end)

      Jidoka.Debug.record_prompt_preview(
        %{
          Jidoka.Subagent.server_key() => pid,
          Jidoka.Subagent.request_id_key() => request_id
        },
        "You are a concise assistant. Use the add_numbers tool.",
        %{
          messages: [%{role: :user, content: "live prompt"}],
          tools: %{"add_numbers" => %{name: "add_numbers"}}
        }
      )

      {:ok, summary} = Jidoka.Debug.request_summary(pid)

      assert summary.request_id == request_id
      assert summary.status == :pending
      assert summary.system_prompt == "You are a concise assistant. Use the add_numbers tool."
      assert summary.prompt_preview.system_prompt == "You are a concise assistant. Use the add_numbers tool."
      assert summary.prompt_preview.user_message == "live prompt"
      assert summary.prompt_preview.message_count == 1
      assert summary.tool_names == ["add_numbers"]
      assert summary.message_count == 1
      assert summary.input_message == "live prompt"
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "normalizes missing-agent debug lookups" do
    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             Jidoka.inspect_request("missing-debug-agent-#{System.unique_integer([:positive])}")

    assert error.phase == :debug
    assert error.details.operation == :debug
    assert error.details.cause == :not_found
  end

  test "summarizes interrupted and failed requests" do
    interrupt =
      Jidoka.Interrupt.new(
        id: "approval",
        kind: :approval,
        message: "Approval required",
        data: %{amount: 100}
      )

    interrupted_request_id = "req-debug-interrupted"

    interrupted_agent =
      JidokaTest.ToolAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(interrupted_request_id, "needs approval")
      |> Request.fail_request(interrupted_request_id, {:interrupt, interrupt})

    assert {:ok, interrupted} = Jidoka.Debug.request_summary(interrupted_agent, interrupted_request_id)
    assert interrupted.status == :failed
    assert interrupted.input_message == "needs approval"
    assert interrupted.interrupt == interrupt
    assert interrupted.error == {:interrupt, interrupt}

    failed_request_id = "req-debug-failed"
    failure = RuntimeError.exception("provider failed")

    failed_agent =
      JidokaTest.ToolAgent.runtime_module()
      |> new_runtime_agent()
      |> Request.start_request(failed_request_id, "will fail")
      |> Request.fail_request(failed_request_id, failure)

    assert {:ok, failed} = Jidoka.Debug.request_summary(failed_agent, failed_request_id)
    assert failed.status == :failed
    assert failed.input_message == "will fail"
    assert failed.prompt_preview.user_message == "will fail"
    assert failed.error == failure
  end
end
