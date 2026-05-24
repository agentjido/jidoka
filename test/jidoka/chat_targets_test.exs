defmodule JidokaTest.ChatTargetsTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Session
  alias JidokaTest.ChatAgent

  test "Jidoka.chat accepts module, pid, id, and session targets" do
    module_id = ChatAgent.id()
    pid_id = unique_id("chat-target")
    session = Session.new!(agent: ChatAgent, id: unique_id("session-target"))

    on_exit(fn ->
      stop_if_running(module_id)
      stop_if_running(pid_id)
      stop_if_running(session.agent_id)
    end)

    stop_if_running(module_id)

    module_guardrail = interrupting_guardrail(:module)
    pid_guardrail = interrupting_guardrail(:pid)
    id_guardrail = interrupting_guardrail(:id)
    session_guardrail = interrupting_guardrail(:session)

    assert {:interrupt, %Jidoka.Interrupt{kind: :module}} =
             Jidoka.chat(ChatAgent, "hello", guardrails: [input: module_guardrail])

    assert is_pid(Jidoka.whereis(module_id))
    assert_receive {:chat_target, :module, ^module_id, context}
    assert Jidoka.Context.strip_internal(context) == %{}

    assert {:ok, pid} = ChatAgent.start_link(id: pid_id)

    assert {:interrupt, %Jidoka.Interrupt{kind: :pid}} =
             Jidoka.chat(pid, "hello", guardrails: [input: pid_guardrail])

    assert_receive {:chat_target, :pid, ^pid_id, _context}

    assert {:interrupt, %Jidoka.Interrupt{kind: :id}} =
             Jidoka.chat(pid_id, "hello", guardrails: [input: id_guardrail])

    assert_receive {:chat_target, :id, ^pid_id, _context}

    assert {:interrupt, %Jidoka.Interrupt{kind: :session}} =
             Jidoka.chat(session, "hello", guardrails: [input: session_guardrail])

    assert_receive {:chat_target, :session, session_agent_id, context}
    assert session_agent_id == session.agent_id
    assert Jidoka.Context.strip_internal(context) == %{session: session.id}
  end

  defp interrupting_guardrail(kind) do
    test_pid = self()

    fn input ->
      send(test_pid, {:chat_target, kind, input.agent.id, input.context})
      {:interrupt, %{kind: kind, message: "#{kind} target", data: %{}}}
    end
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp stop_if_running(id) do
    case Jidoka.whereis(id) do
      pid when is_pid(pid) -> Jidoka.stop_agent(pid)
      nil -> :ok
    end
  end
end
