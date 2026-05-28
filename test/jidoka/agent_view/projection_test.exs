defmodule JidokaTest.AgentViewTest do
  use ExUnit.Case, async: true

  alias Jido.Thread

  test "projects LLM context separately from visible messages" do
    thread =
      Thread.new(id: "thread-support-1")
      |> Thread.append([
        ai_message(:user, "I need a refund.", request_id: "req-1"),
        ai_message(:assistant, "", request_id: "req-1", tool_calls: [%{id: "call-1", name: "review_refund"}]),
        ai_message(:tool, ~s({"decision":"approve"}),
          request_id: "req-1",
          tool_call_id: "call-1",
          name: "review_refund"
        ),
        ai_message(:assistant, "The refund is approved.", request_id: "req-1")
      ])

    projection = Jidoka.Agent.View.project(thread)

    assert projection.thread_id == "thread-support-1"
    assert projection.entry_count == 4
    assert Enum.map(projection.llm_context, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Enum.map(projection.visible_messages, & &1.role) == [:user, :assistant]
    assert Enum.map(projection.visible_messages, & &1.content) == ["I need a refund.", "The refund is approved."]

    assert [
             %{kind: :tool_call, label: "tool call: review_refund"},
             %{kind: :tool_result, label: "tool result: review_refund"}
           ] = projection.events
  end

  test "projects debug events with bounded redacted payloads" do
    secret = "sk-ant-secret12345678901234567890"
    long_result = "token=#{secret} " <> String.duplicate("tool output ", 80)

    thread =
      Thread.new(id: "thread-debug-projection")
      |> Thread.append([
        ai_message(:assistant, "",
          request_id: "req-safe",
          tool_calls: [
            %{
              id: "call-safe",
              name: "lookup_ticket",
              arguments: %{api_key: secret, query: "raw prompt"}
            }
          ]
        ),
        ai_message(:tool, long_result,
          request_id: "req-safe",
          tool_call_id: "call-safe",
          name: "lookup_ticket",
          api_key: secret
        ),
        context_operation(
          %{
            context_ref: "default",
            content: long_result,
            raw_response: "raw provider body #{secret}",
            api_key: secret
          },
          %{request_id: "req-safe", token: secret}
        )
      ])

    projection = Jidoka.Agent.View.project(thread)

    assert [
             %{kind: :tool_call, payload: tool_call_payload},
             %{kind: :tool_result, payload: tool_result_payload},
             %{kind: :context_operation, payload: context_payload, refs: context_refs}
           ] = projection.events

    assert tool_call_payload.arguments == "[OMITTED]"
    assert tool_result_payload.api_key == "[REDACTED]"
    assert tool_result_payload.content =~ "token=[REDACTED]"
    assert String.length(tool_result_payload.content) <= 240
    assert context_payload.raw_response == "[OMITTED]"
    assert context_payload.api_key == "[REDACTED]"
    assert context_payload.content =~ "token=[REDACTED]"
    assert context_refs.token == "[REDACTED]"

    rendered = inspect(projection.events)
    refute rendered =~ secret
    refute rendered =~ "raw provider body"
  end

  test "filters projections by context ref" do
    thread =
      Thread.new()
      |> Thread.append([
        ai_message(:user, "Default context", context_ref: "default"),
        ai_message(:user, "Support context", context_ref: "support")
      ])

    assert %{visible_messages: [%{content: "Default context"}]} = Jidoka.Agent.View.project(thread)

    assert %{visible_messages: [%{content: "Support context"}]} =
             Jidoka.Agent.View.project(thread, context_ref: "support")
  end

  test "projects in-flight streaming assistant message from strategy state" do
    agent = %Jido.Agent{
      id: "support-router",
      state: %{
        __strategy__: %{
          status: :awaiting_llm,
          active_request_id: "req-stream",
          streaming_text: "Refund review is still running",
          streaming_thinking: "Checking policy"
        }
      }
    }

    assert {:ok, %{streaming_message: streaming_message}} = Jidoka.Agent.View.snapshot(agent)

    assert streaming_message == %{
             id: "streaming-req-stream",
             seq: -1,
             role: :assistant,
             content: "Refund review is still running",
             request_id: "req-stream",
             run_id: "req-stream",
             streaming?: true,
             thinking: "Checking policy"
           }
  end

  test "does not project completed streaming text as a visible draft" do
    agent = %Jido.Agent{
      id: "support-router",
      state: %{
        __strategy__: %{
          status: :completed,
          active_request_id: nil,
          streaming_text: "Final answer",
          streaming_thinking: ""
        }
      }
    }

    assert {:ok, %{streaming_message: nil}} = Jidoka.Agent.View.snapshot(agent)
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

  defp context_operation(payload, refs) do
    %{
      kind: :ai_context_operation,
      payload: payload,
      refs: refs
    }
  end
end
