defmodule Jidoka.MemoryTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Memory
  alias Jidoka.Memory.Store.InMemory
  alias Jidoka.Memory.Store.JidoMemory
  alias Jidoka.Turn

  test "memory facade delegates to runtime policies" do
    spec =
      Agent.Spec.new!(
        id: "memory_facade_agent",
        instructions: "Remember useful context.",
        model: %{provider: :test, id: "model"},
        memory: %{enabled: true, scope: :session, capture: "off"}
      )

    request = Turn.Request.new!(input: "What do you remember?")

    result =
      Turn.Result.new!(
        content: "Nothing yet.",
        agent_state: Agent.State.new!(),
        journal: Jidoka.Effect.Journal.new!()
      )

    assert {:ok, nil} = Memory.recall(spec, request)
    assert {:error, :missing_memory_store} = Memory.write(spec, "Ada prefers terse replies.")
    assert {:ok, nil} = Memory.capture_turn(spec, request, result)
  end

  test "memory policy normalizes boolean and string values" do
    assert {:ok, %Agent.Spec.Memory{scope: :agent, max_entries: 5}} =
             Agent.Spec.Memory.from_input(true)

    assert {:ok, nil} = Agent.Spec.Memory.from_input(false)

    assert {:ok, %Agent.Spec.Memory{scope: :session, max_entries: 2}} =
             Agent.Spec.Memory.from_input(%{"scope" => "session", "max_entries" => "2"})

    assert {:ok,
            %Agent.Spec.Memory{
              scope: :agent,
              namespace: "shared:team",
              capture: :conversation,
              inject: :context,
              max_entries: 9
            }} =
             Agent.Spec.Memory.from_input(%{
               "namespace" => "shared",
               "shared_namespace" => "team",
               "capture" => "conversation",
               "inject" => "context",
               "retrieve" => %{"limit" => 9}
             })
  end

  test "memory entries and write results are serializable data" do
    entry =
      Memory.Entry.new!(
        [agent_id: "memory_agent", content: "Ada prefers concise answers."],
        id_generator: fn "mem" -> "mem_test" end
      )

    request = Memory.WriteRequest.new!(entry: entry)

    assert %Memory.WriteResult{entry: ^entry, status: :ok} =
             Memory.WriteResult.new!(request: request, entry: entry)

    assert {:ok, ^entry} = Memory.Entry.from_input(entry)

    assert {:error, {:invalid_generated_id, "mem", ""}} =
             Memory.Entry.new([agent_id: "memory_agent", content: "bad"],
               id_generator: fn "mem" -> "" end
             )

    assert {:error, _reason} = Memory.RecallRequest.new(agent_id: "memory_agent", query: "")
    assert {:error, _reason} = Memory.WriteRequest.new(entry: %{content: "missing agent"})

    assert_raise ArgumentError, ~r/invalid memory entry/, fn ->
      Memory.Entry.new!(agent_id: "memory_agent", content: "")
    end

    assert_raise ArgumentError, ~r/invalid memory recall request/, fn ->
      Memory.RecallRequest.new!(agent_id: "memory_agent")
    end

    assert_raise ArgumentError, ~r/invalid memory write result/, fn ->
      Memory.WriteResult.new!(request: request, entry: %{content: "missing agent"})
    end
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

  test "memory writes require context namespace values when configured" do
    {:ok, pid} = InMemory.start_link()

    spec =
      Agent.Spec.new!(
        id: "context_namespace_memory_agent",
        instructions: "Remember tenant-scoped details.",
        model: %{provider: :test, id: "model"},
        memory: %{enabled: true, scope: :agent, namespace: {:context, :tenant_id}}
      )

    store = {InMemory, pid: pid}

    assert {:error, {:missing_memory_namespace_context, :tenant_id}} =
             Memory.write(spec, "Do not write without a tenant.", memory_store: store)

    assert {:ok, %Memory.WriteResult{entry: %{content: "Tenant-scoped memory."}}} =
             Memory.write(spec, "Tenant-scoped memory.",
               memory_store: store,
               context: %{tenant_id: "tenant_a"}
             )
  end

  test "jido_memory store writes and recalls entries through the Jido memory runtime" do
    table = :"jidoka_memory_test_#{System.unique_integer([:positive])}"
    :ok = Jido.Memory.Store.ETS.ensure_ready(table: table)

    store =
      {JidoMemory, namespace: "jidoka:test", provider_opts: [store: {Jido.Memory.Store.ETS, [table: table]}]}

    entry =
      Memory.Entry.new!(
        id: "mem_jido",
        agent_id: "memory_agent",
        session_id: "sess_1",
        content: "Ada prefers short answers.",
        metadata: %{"tags" => ["preference"]}
      )

    request = Memory.WriteRequest.new!(entry: entry)
    assert {:ok, %Memory.WriteResult{entry: written}} = Memory.Store.write(store, request)
    assert written.id == "mem_jido"

    recall =
      Memory.RecallRequest.new!(
        agent_id: "memory_agent",
        session_id: "sess_1",
        scope: :session,
        query: "How should I answer?",
        limit: 5
      )

    assert {:ok, %Memory.RecallResult{entries: [recalled], metadata: metadata}} =
             Memory.Store.recall(store, recall)

    assert recalled.id == "mem_jido"
    assert recalled.content == "Ada prefers short answers."
    assert metadata["namespace"] == "jidoka:test:session:sess_1"

    assert {:ok, [listed]} =
             Memory.Store.list_entries(
               {JidoMemory,
                namespace: "jidoka:test",
                scope: :session,
                session_id: "sess_1",
                provider_opts: [store: {Jido.Memory.Store.ETS, [table: table]}]}
             )

    assert listed.id == "mem_jido"
  end
end
