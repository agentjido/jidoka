defmodule Jidoka.SessionAtomicContinuationTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Schema
  alias Jidoka.Session
  alias Jidoka.Session.Conversation
  alias Jidoka.Session.Data
  alias Jidoka.Session.Store.Dets
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Session.Transitions
  alias Jidoka.Turn

  test "caller-owned session calls continue the committed transcript" do
    assert {:ok, session} = Session.start(spec(), "caller-continuation")
    assert {:ok, completed} = run_two_calls(session, [])
    assert_completed_conversation(completed)
  end

  test "in-memory session calls continue the committed transcript" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    assert {:ok, _session} = Session.start(spec(), "memory-continuation", store: store)
    assert {:ok, completed} = run_two_calls("memory-continuation", store: store)
    assert_completed_conversation(completed)

    assert {:ok, stored} = Session.get(store, "memory-continuation")
    assert stored.conversation == completed.conversation
  end

  test "DETS session calls continue after the store restarts" do
    path = Path.join(System.tmp_dir!(), "jidoka-atomic-#{System.unique_integer([:positive])}.dets")
    table = :jidoka_session_atomic_continuation_test
    on_exit(fn -> File.rm(path) end)

    {:ok, first_pid} = Dets.start_link(path: path, table: table)
    first_store = {Dets, pid: first_pid}

    assert {:ok, _session} = Session.start(spec(), "dets-continuation", store: first_store)
    assert {:ok, first} = run_first_call("dets-continuation", store: first_store)
    :ok = GenServer.stop(first_pid)

    {:ok, second_pid} = Dets.start_link(path: path, table: table)
    second_store = {Dets, pid: second_pid}

    assert {:ok, completed} = run_second_call("dets-continuation", store: second_store)
    assert completed.conversation.continuation_revision == first.conversation.continuation_revision + 1
    assert_completed_conversation(completed)

    :ok = GenServer.stop(second_pid)
  end

  test "failure and cancellation do not promote the completed conversation" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    for {session_id, reason} <- [
          {"failed-continuation", :provider_offline},
          {"cancelled-continuation", :cancelled}
        ] do
      assert {:ok, _session} = Session.start(spec(), session_id, store: store)
      assert {:ok, completed} = run_first_call(session_id, store: store)
      committed = completed.conversation

      failing_llm = fn _intent, _journal, _context -> {:error, reason} end

      assert {:error, _reason} =
               Session.run(session_id, "This turn must not commit",
                 store: store,
                 request_id: "#{session_id}-failed",
                 llm: failing_llm
               )

      assert {:ok, stored} = Session.get(store, session_id)
      assert stored.conversation == committed
      assert stored.conversation.last_completed_request_id == "#{session_id}-first"

      expected_status = if Cancellation.cancelled_reason?(reason), do: :cancelled, else: :error
      assert stored.status == expected_status
    end
  end

  test "fresh conversation replaces history only after success" do
    assert {:ok, session} = Session.start(spec(), "fresh-continuation")
    assert {:ok, first} = run_first_call(session, [])

    llm = fn intent, _journal, _context ->
      assert conversation_messages(intent) == [
               {:user, "Start over"}
             ]

      {:ok, %{type: :final, content: "Fresh answer"}}
    end

    assert {:ok, fresh, _result} =
             Session.run(first, "Start over",
               request_id: "fresh-second",
               fresh_conversation: true,
               llm: llm
             )

    assert fresh.conversation.continuation_revision == 1
    assert fresh.conversation.turn_count == 1
    assert fresh.conversation.last_completed_request_id == "fresh-second"

    assert Enum.map(fresh.conversation.agent_state.messages, &{&1.role, &1.content}) == [
             {:user, "Start over"},
             {:assistant, "Fresh answer"}
           ]

    assert {:error, {:invalid_fresh_conversation_option, :yes}} =
             Session.run(fresh, "Invalid", fresh_conversation: :yes, llm: llm)
  end

  test "a stale prepared request cannot claim a newer conversation revision" do
    assert {:ok, %Data{} = session} = Session.start(spec(), "stale-continuation")
    request = Turn.Request.new!(input: "Stale", request_id: "stale-request")
    assert {:ok, prepared} = Conversation.prepare_request(session.conversation, request, [])

    current_conversation =
      Conversation.new!(
        continuation_revision: 1,
        turn_count: 1,
        last_completed_request_id: "other-request"
      )

    current = %Data{session | conversation: current_conversation}

    assert {:error, {:stale_conversation_revision, "stale-continuation", 0, 1}} =
             Transitions.claim_without_lease(current, prepared)
  end

  defp run_two_calls(session_input, opts) do
    case run_first_call(session_input, opts) do
      {:ok, first} -> run_second_call(session_ref(first, session_input), opts)
      error -> error
    end
  end

  defp run_first_call(session_input, opts) do
    session_id = session_id(session_input)

    llm = fn intent, _journal, _context ->
      assert conversation_messages(intent) == [{:user, "First question"}]
      {:ok, %{type: :final, content: "First answer"}}
    end

    case Session.run(
           session_input,
           "First question",
           Keyword.merge(opts, request_id: "#{session_id}-first", llm: llm)
         ) do
      {:ok, session, _result} -> {:ok, session}
      other -> other
    end
  end

  defp run_second_call(session_input, opts) do
    session_id = session_id(session_input)

    llm = fn intent, _journal, _context ->
      assert conversation_messages(intent) == [
               {:user, "First question"},
               {:assistant, "First answer"},
               {:user, "Second question"}
             ]

      {:ok, %{type: :final, content: "Second answer"}}
    end

    case Session.run(
           session_input,
           "Second question",
           Keyword.merge(opts, request_id: "#{session_id}-second", llm: llm)
         ) do
      {:ok, session, _result} -> {:ok, session}
      other -> other
    end
  end

  defp assert_completed_conversation(%Data{} = session) do
    assert session.conversation.continuation_revision == 2
    assert session.conversation.turn_count == 2
    assert session.conversation.last_completed_request_id == "#{session.session_id}-second"

    assert Enum.map(session.conversation.agent_state.messages, &{&1.role, &1.content}) == [
             {:user, "First question"},
             {:assistant, "First answer"},
             {:user, "Second question"},
             {:assistant, "Second answer"}
           ]
  end

  defp conversation_messages(intent) do
    intent.payload
    |> Schema.get_key(:prompt)
    |> Schema.get_key(:messages, [])
    |> Enum.reject(&(Schema.get_key(&1, :role) in [:system, "system"]))
    |> Enum.map(fn message ->
      {normalize_role(Schema.get_key(message, :role)), Schema.get_key(message, :content)}
    end)
  end

  defp normalize_role(role) when is_atom(role), do: role
  defp normalize_role(role), do: String.to_existing_atom(role)

  defp session_ref(%Data{} = session, %Data{}), do: session
  defp session_ref(%Data{} = session, _session_id), do: session.session_id

  defp session_id(%Data{session_id: session_id}), do: session_id
  defp session_id(session_id), do: session_id

  defp spec do
    Agent.Spec.new!(
      id: "atomic_continuation_agent",
      instructions: "Answer each question.",
      model: %{provider: :test, id: "model"}
    )
  end
end
