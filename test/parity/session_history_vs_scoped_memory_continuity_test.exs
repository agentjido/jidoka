defmodule Jidoka.Parity.SessionHistoryVsScopedMemoryContinuityTest do
  use Jidoka.ParityCase, parity: :session_history_vs_scoped_memory_continuity

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Session.Data, as: SessionData
  alias Jidoka.Session.Store.InMemory, as: SessionStore
  alias Jidoka.Memory.Store.InMemory, as: MemoryStore
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Schema
  alias Jidoka.Session
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  @operation_name "lookup_session_evidence"
  @operation_arguments %{"scope" => "session-a"}
  @operation_output %{
    "evidence" => "A1 scoped tool observation",
    "scope" => "session-a"
  }

  test "session continuation is canonical, durable, and isolated from scoped memory" do
    {:ok, session_pid} = SessionStore.start_link()
    {:ok, memory_pid} = MemoryStore.start_link()
    session_store = {SessionStore, pid: session_pid}
    memory_store = {MemoryStore, pid: memory_pid}
    test_pid = self()

    operations =
      LocalOperations.operations(%{
        @operation_name => fn arguments, _context ->
          send(test_pid, {:a1_operation_called, arguments})
          @operation_output
        end
      })

    assert {:ok, %SessionData{session_id: "parity-session-a"} = session_a} =
             Session.start(spec(), "parity-session-a", store: session_store)

    assert {:ok, %SessionData{session_id: "parity-session-b"}} =
             Session.start(spec(), "parity-session-b", store: session_store)

    assert {:ok, write_result} =
             Session.write_memory(session_a, "Session A prefers concise evidence.",
               memory_store: memory_store,
               id_generator: fn "mem" -> "mem-parity-session-a" end
             )

    assert write_result.entry.content == "Session A prefers concise evidence."

    first_llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _context ->
      prompt = Schema.get_key(payload, :prompt)
      messages = Schema.get_key(prompt, :messages, [])

      assert Schema.get_key(prompt, :memory).count == 1
      assert message_with_content?(messages, "Session A prefers concise evidence.")
      refute message_with_content?(messages, "A1 assistant evidence")

      case count_results(journal, :llm) do
        0 ->
          refute tool_observation?(messages, @operation_name, @operation_output)

          {:ok,
           %{
             type: :operation,
             name: @operation_name,
             arguments: @operation_arguments
           }}

        1 ->
          assert tool_observation?(messages, @operation_name, @operation_output)
          {:ok, %{type: :final, content: "A1 assistant evidence"}}

        unexpected ->
          raise "unexpected A1 model call #{unexpected}"
      end
    end

    assert {:ok, %SessionData{} = after_a1, %Turn.Result{} = first_result} =
             Session.run(
               "parity-session-a",
               Turn.Request.new!(input: "A1 user request", request_id: "parity-a1"),
               store: session_store,
               memory_store: memory_store,
               llm: first_llm,
               operations: operations
             )

    assert_receive {:a1_operation_called, @operation_arguments}
    refute_receive {:a1_operation_called, _arguments}

    assert after_a1.requests |> Enum.map(& &1.input) == ["A1 user request"]
    assert after_a1.result == first_result
    assert first_result.content == "A1 assistant evidence"
    assert memory_event_count(first_result) == 1

    assert tool_observation?(
             first_result.agent_state.messages,
             @operation_name,
             @operation_output
           )

    assert [
             %Effect.OperationResult{
               operation: @operation_name,
               arguments: @operation_arguments,
               output: @operation_output
             }
           ] = first_result.agent_state.operation_results

    continued_second_llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      prompt = Schema.get_key(payload, :prompt)
      messages = Schema.get_key(prompt, :messages, [])

      assert Schema.get_key(prompt, :memory).count == 1
      assert message_with_content?(messages, "Session A prefers concise evidence.")
      assert message_with_content?(messages, "A1 assistant evidence")
      assert message_with_content?(messages, "A1 user request")
      assert tool_observation?(messages, @operation_name, @operation_output)
      assert message_with_content?(messages, "A2 user request")

      {:ok, %{type: :final, content: "A2 fresh assistant evidence"}}
    end

    assert {:ok, %SessionData{} = after_a2, %Turn.Result{} = ordinary_second_result} =
             Session.run(
               "parity-session-a",
               Turn.Request.new!(input: "A2 user request", request_id: "parity-a2"),
               store: session_store,
               memory_store: memory_store,
               llm: continued_second_llm,
               operations: operations
             )

    assert Enum.map(after_a2.requests, & &1.input) == ["A1 user request", "A2 user request"]
    assert after_a2.result == ordinary_second_result
    assert state_message_with_content?(ordinary_second_result, "A1 assistant evidence")
    assert state_message_with_content?(ordinary_second_result, "A1 user request")
    assert state_message_with_content?(ordinary_second_result, "A2 fresh assistant evidence")

    assert tool_observation?(
             ordinary_second_result.agent_state.messages,
             @operation_name,
             @operation_output
           )

    assert [%Effect.OperationResult{operation: @operation_name}] =
             ordinary_second_result.agent_state.operation_results

    canonical_third_llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      prompt = Schema.get_key(payload, :prompt)
      messages = Schema.get_key(prompt, :messages, [])

      assert Schema.get_key(prompt, :memory).count == 1
      assert message_with_content?(messages, "Session A prefers concise evidence.")
      assert message_with_content?(messages, "A1 assistant evidence")
      assert message_with_content?(messages, "A1 user request")
      assert message_with_content?(messages, "A2 user request")
      assert message_with_content?(messages, "A2 fresh assistant evidence")
      assert tool_observation?(messages, @operation_name, @operation_output)
      assert message_with_content?(messages, "A3 user request")
      refute message_with_content?(messages, "caller-injected history")

      {:ok, %{type: :final, content: "A3 continued assistant evidence"}}
    end

    caller_request =
      Turn.Request.new!(
        input: "A3 user request",
        request_id: "parity-a3",
        agent_state: Agent.State.new!(messages: [Agent.Message.assistant("caller-injected history")])
      )

    assert {:ok, %SessionData{} = after_a3, %Turn.Result{} = third_result} =
             Session.run("parity-session-a", caller_request,
               store: session_store,
               memory_store: memory_store,
               llm: canonical_third_llm,
               operations: operations
             )

    assert Enum.map(after_a3.requests, & &1.input) == [
             "A1 user request",
             "A2 user request",
             "A3 user request"
           ]

    assert after_a3.result == third_result
    assert state_message_with_content?(third_result, "A1 assistant evidence")
    assert state_message_with_content?(third_result, "A1 user request")
    assert state_message_with_content?(third_result, "A2 fresh assistant evidence")
    assert state_message_with_content?(third_result, "A3 continued assistant evidence")
    refute state_message_with_content?(third_result, "caller-injected history")

    assert tool_observation?(
             third_result.agent_state.messages,
             @operation_name,
             @operation_output
           )

    assert [
             %Effect.OperationResult{
               operation: @operation_name,
               arguments: @operation_arguments,
               output: @operation_output
             }
           ] = third_result.agent_state.operation_results

    assert memory_event_count(third_result) == 1

    assert {:ok, %SessionData{result: ^third_result} = stored_after_a3} =
             Session.get(session_store, "parity-session-a")

    assert stored_after_a3 == after_a3

    session_b_llm = fn %Effect.Intent{payload: payload}, _journal, _context ->
      prompt = Schema.get_key(payload, :prompt)
      messages = Schema.get_key(prompt, :messages, [])

      assert Schema.get_key(prompt, :memory).count == 0
      refute message_with_content?(messages, "Session A prefers concise evidence.")
      refute message_with_content?(messages, "A1 assistant evidence")
      refute tool_observation?(messages, @operation_name, @operation_output)

      {:ok, %{type: :final, content: "B isolated assistant evidence"}}
    end

    assert {:ok, %SessionData{} = after_b1, %Turn.Result{} = b_result} =
             Session.run(
               "parity-session-b",
               Turn.Request.new!(input: "B1 user request", request_id: "parity-b1"),
               store: session_store,
               memory_store: memory_store,
               llm: session_b_llm,
               operations: operations
             )

    assert Enum.map(after_b1.requests, & &1.input) == ["B1 user request"]
    assert after_b1.result == b_result
    assert memory_event_count(b_result) == 0
    refute tool_observation?(b_result.agent_state.messages, @operation_name, @operation_output)
    assert b_result.agent_state.operation_results == []
  end

  defp spec do
    Agent.Spec.new!(
      id: "parity_session_memory_agent",
      instructions: "Use only the session state and scoped memory supplied for this request.",
      model: %{provider: :test, id: "scripted-model"},
      operations: [
        Operation.new!(
          name: @operation_name,
          description: "Returns deterministic session-continuity evidence.",
          idempotency: :idempotent
        )
      ],
      memory: %{scope: :session, max_entries: 3}
    )
  end

  defp memory_event_count(%Turn.Result{events: events}) do
    case Enum.find(events, &(&1.event == :memory_recalled)) do
      nil -> 0
      event -> Schema.get_key(event.data, :count)
    end
  end

  defp state_message_with_content?(%Turn.Result{} = result, expected) do
    message_with_content?(result.agent_state.messages, expected)
  end

  defp message_with_content?(messages, expected) do
    Enum.any?(messages, fn message ->
      message
      |> Schema.get_key(:content, "")
      |> to_string()
      |> String.contains?(expected)
    end)
  end

  defp tool_observation?(messages, operation, expected_output) do
    Enum.any?(messages, fn message ->
      Schema.get_key(message, :role) == :tool and
        Schema.get_key(message, :operation) == operation and
        Schema.get_key(message, :output) == expected_output
    end)
  end
end
