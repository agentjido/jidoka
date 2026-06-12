defmodule Jidoka.SessionTest.Support.DslAgent do
  @moduledoc false

  use Jidoka.Agent

  agent :session_facade_agent do
    model %{provider: :test, id: "model"}
    instructions "Answer through the session facade."
  end
end

defmodule Jidoka.SessionTest do
  use ExUnit.Case, async: true

  @chat_uuid7_regex ~r/\Achat_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  alias Jidoka.Harness
  alias Jidoka.Harness.Session, as: HarnessSession
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Chat.Request
  alias Jidoka.Session
  alias Jidoka.SessionTest.Support.DslAgent
  alias Jidoka.Turn

  test "root session facade starts a persisted session from a DSL agent module" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    assert {:ok,
            %HarnessSession{
              session_id: "support-123",
              status: :new,
              spec: %{id: "session_facade_agent"}
            } = session} = Jidoka.session(DslAgent, "support-123", store: store)

    assert {:ok, ^session} = Session.get(store, "support-123")
    assert {:ok, [^session]} = Session.list(store)
  end

  test "session chat returns updated session data with final assistant text" do
    {:ok, session} = Session.start(spec(), "chat-123")

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "session facade ok"}}
    end

    assert {:ok, %HarnessSession{status: :finished} = updated, "session facade ok"} =
             Session.chat(session, "Hello", llm: llm)

    assert %Turn.Result{content: "session facade ok"} = updated.result

    assert {:ok, %HarnessSession{} = root_updated, "session facade ok"} =
             Jidoka.chat(session, "Hello again", llm: llm)

    assert root_updated.status == :finished
  end

  test "session chat can run asynchronously for UI callers" do
    {:ok, session} = Session.start(spec(), "async-chat-123")

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "async session ok"}}
    end

    assert {:ok, request} = Session.chat_async(session, "Hello", llm: llm, stream: true)
    assert request.request_id =~ @chat_uuid7_regex
    assert request.session_id == "async-chat-123"

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)

    assert {:ok, %HarnessSession{status: :finished} = updated, "async session ok"} =
             Jidoka.await(stream, timeout: 1_000)

    assert updated.session_id == "async-chat-123"

    assert [:turn_started | _] = stream |> Enum.map(& &1.event)
  end

  test "persisted session ids can run asynchronously through the session facade" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    assert {:ok, %HarnessSession{session_id: "async-stored-123"}} =
             Session.start(spec(), "async-stored-123", store: store)

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "async stored ok"}}
    end

    assert {:ok, request} =
             Session.chat_async("async-stored-123", "Hello", store: store, llm: llm)

    assert {:ok, %HarnessSession{session_id: "async-stored-123"}, "async stored ok"} =
             Session.await(request, timeout: 1_000)
  end

  test "await cancels timed out async chat requests by default" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:chat_task_started, self()})
        Process.sleep(5_000)
        {:ok, :late}
      end)

    request =
      Request.new(
        request_id: "chat_cancel_test",
        task: task,
        target: :test,
        session_id: nil,
        stream_to: nil,
        started_at_ms: System.system_time(:millisecond),
        metadata: %{}
      )

    assert_receive {:chat_task_started, task_pid}
    assert {:error, :timeout} = Request.await(request, timeout: 5)
    refute Process.alive?(task_pid)
  end

  test "session run can resolve persisted sessions by id" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    assert {:ok, %HarnessSession{session_id: "stored-123"}} =
             Session.start(spec(), id: "stored-123", store: store)

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :final, content: "stored session ok"}}
    end

    assert {:ok, %HarnessSession{status: :finished} = session, %Turn.Result{content: "stored session ok"}} =
             Session.run("stored-123", "Hello", store: store, llm: llm)

    assert {:ok, %HarnessSession{status: :finished, result: %Turn.Result{}}} =
             Session.get(store, "stored-123")

    assert {:ok, %Harness.Replay{session_id: "stored-123"}} = Session.replay(session)
  end

  test "session start rejects conflicting id aliases" do
    assert {:error, {:conflicting_session_ids, "alias-id", "session-id"}} =
             Session.start(spec(), id: "alias-id", session_id: "session-id")
  end

  defp spec do
    Jidoka.agent!(
      id: "session_test_agent",
      instructions: "Answer through a test spec.",
      model: %{provider: :test, id: "model"}
    )
  end
end
