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

  alias Jidoka.Harness
  alias Jidoka.Harness.Session, as: HarnessSession
  alias Jidoka.Harness.Store.InMemory
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

    llm = fn _intent, _journal ->
      {:ok, %{type: :final, content: "session facade ok"}}
    end

    assert {:ok, %HarnessSession{status: :finished} = updated, "session facade ok"} =
             Session.chat(session, "Hello", llm: llm)

    assert %Turn.Result{content: "session facade ok"} = updated.result

    assert {:ok, %HarnessSession{} = root_updated, "session facade ok"} =
             Jidoka.chat(session, "Hello again", llm: llm)

    assert root_updated.status == :finished
  end

  test "session run can resolve persisted sessions by id" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    assert {:ok, %HarnessSession{session_id: "stored-123"}} =
             Session.start(spec(), id: "stored-123", store: store)

    llm = fn _intent, _journal ->
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
