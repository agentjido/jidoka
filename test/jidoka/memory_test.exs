defmodule Jidoka.MemoryTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Memory
  alias Jidoka.Memory.Store.InMemory

  test "memory policy normalizes boolean and string values" do
    assert {:ok, %Agent.Spec.Memory{scope: :agent, max_entries: 5}} =
             Agent.Spec.Memory.from_input(true)

    assert {:ok, nil} = Agent.Spec.Memory.from_input(false)

    assert {:ok, %Agent.Spec.Memory{scope: :session, max_entries: 2}} =
             Agent.Spec.Memory.from_input(%{"scope" => "session", "max_entries" => "2"})
  end

  test "memory entries, write results, and compactions are serializable data" do
    entry =
      Memory.Entry.new!(
        [agent_id: "memory_agent", content: "Ada prefers concise answers."],
        id_generator: fn "mem" -> "mem_test" end
      )

    request = Memory.WriteRequest.new!(entry: entry)

    assert %Memory.WriteResult{entry: ^entry, status: :ok} =
             Memory.WriteResult.new!(request: request, entry: entry)

    assert %Memory.Compaction{
             id: "cmp_test",
             source_message_ids: ["msg_1", "msg_2"]
           } =
             Memory.Compaction.new!(
               [
                 agent_id: "memory_agent",
                 summary: "The user prefers concise answers.",
                 source_message_ids: ["msg_1", "msg_2"]
               ],
               id_generator: fn "cmp" -> "cmp_test" end
             )
  end

  test "in-memory store writes and recalls matching entries" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    agent_entry =
      Memory.Entry.new!(
        id: "mem_agent",
        agent_id: "memory_agent",
        content: "Use short answers."
      )

    session_entry =
      Memory.Entry.new!(
        id: "mem_session",
        agent_id: "memory_agent",
        session_id: "sess_1",
        content: "This session is about invoices."
      )

    other_entry =
      Memory.Entry.new!(
        id: "mem_other",
        agent_id: "other_agent",
        content: "Not relevant."
      )

    for entry <- [agent_entry, session_entry, other_entry] do
      request = Memory.WriteRequest.new!(entry: entry)
      assert {:ok, %Memory.WriteResult{entry: ^entry}} = Memory.Store.write(store, request)
    end

    recall =
      Memory.RecallRequest.new!(
        agent_id: "memory_agent",
        session_id: "sess_1",
        query: "invoice",
        limit: 5
      )

    assert {:ok, %Memory.RecallResult{entries: entries}} = Memory.Store.recall(store, recall)
    assert Enum.map(entries, & &1.id) == ["mem_session", "mem_agent"]

    assert {:ok, all_entries} = Memory.Store.list_entries(store)
    assert Enum.map(all_entries, & &1.id) == ["mem_agent", "mem_session", "mem_other"]
  end
end
