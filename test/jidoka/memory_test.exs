defmodule Jidoka.MemoryTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Memory
  alias Jidoka.Memory.Store.InMemory
  alias Jidoka.Memory.Store.JidoMemory
  alias Jidoka.Turn

  defmodule FakeJidoMemoryRuntime do
    @moduledoc false

    def retrieve(target, query, opts) do
      send(self(), {:jido_memory_retrieve, target, query, opts})
      {:ok, %{records: Process.get({__MODULE__, :records}, []), total_count: 7}}
    end

    def remember(target, attrs, opts) do
      send(self(), {:jido_memory_remember, target, attrs, opts})

      {:ok,
       %{
         id: attrs.id,
         namespace: attrs.namespace,
         class: attrs.class,
         kind: attrs.kind,
         text: attrs.text,
         content: attrs.content,
         tags: attrs.tags,
         metadata: attrs.metadata
       }}
    end
  end

  defmodule FakeJidoMemoryRetrieveResult do
    @moduledoc false

    def records(result), do: result.records
  end

  defmodule FakeJidoMemoryStore do
    @moduledoc false
  end

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

  test "memory routes require one complete partition identity" do
    assert {:ok, agent_route} =
             Memory.Route.new(kind: :agent, agent_id: "memory_agent")

    assert {:ok, session_route} =
             Memory.Route.new(
               kind: :session,
               agent_id: "memory_agent",
               session_id: "sess_1"
             )

    assert {:ok, namespace_route} =
             Memory.Route.new(
               kind: :namespace,
               agent_id: "memory_agent",
               namespace: "tenant:acme"
             )

    assert Memory.Route.key(agent_route) == {:agent, "memory_agent"}
    assert Memory.Route.key(session_route) == {:session, "memory_agent", "sess_1"}
    assert Memory.Route.key(namespace_route) == {:namespace, "tenant:acme"}

    assert {:error, :missing_memory_route_session_id} =
             Memory.Route.new(kind: :session, agent_id: "memory_agent")

    assert %Memory.RecallRequest{route: ^session_route} =
             Memory.RecallRequest.new!(
               agent_id: "memory_agent",
               session_id: "sess_1",
               scope: :session,
               query: "legacy"
             )

    assert JidoMemory.namespace(agent_route) == "agent:memory_agent"
    assert JidoMemory.namespace(session_route) == "agent:memory_agent:session:sess_1"
    assert JidoMemory.namespace(namespace_route) == "tenant:acme"
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
    assert Enum.map(entries, & &1.id) == ["mem_session"]

    namespace_route =
      Memory.Route.new!(
        kind: :namespace,
        agent_id: "memory_agent",
        namespace: "tenant:acme"
      )

    namespace_entry =
      Memory.Entry.new!(
        id: "mem_namespace",
        agent_id: "memory_agent",
        content: "Tenant memory."
      )

    assert {:ok, %Memory.WriteResult{}} =
             Memory.Store.write(
               store,
               Memory.WriteRequest.new!(entry: namespace_entry, route: namespace_route)
             )

    namespace_recall =
      Memory.RecallRequest.new!(route: namespace_route, query: "tenant", limit: 5)

    assert {:ok, %Memory.RecallResult{entries: [^namespace_entry]}} =
             Memory.Store.recall(store, namespace_recall)

    assert {:ok, all_entries} = Memory.Store.list_entries(store)
    assert Enum.map(all_entries, & &1.id) == ["mem_agent", "mem_session", "mem_other", "mem_namespace"]
  end

  test "memory stores collapse repeated idempotency keys to one visible entry" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}

    first =
      Memory.Entry.new!(
        id: "mem_first",
        agent_id: "memory_agent",
        content: "First capture"
      )

    second =
      Memory.Entry.new!(
        id: "mem_second",
        agent_id: "memory_agent",
        content: "Repeated capture"
      )

    assert {:ok, %Memory.WriteResult{entry: stored}} =
             Memory.Store.write(
               store,
               Memory.WriteRequest.new!(entry: first, idempotency_key: "capture-key")
             )

    assert stored.content == "First capture"
    refute Map.has_key?(stored.metadata, "idempotency_key")

    assert {:ok, %Memory.WriteResult{entry: ^stored}} =
             Memory.Store.write(
               store,
               Memory.WriteRequest.new!(entry: second, idempotency_key: "capture-key")
             )

    assert {:ok, [^stored]} = Memory.Store.list_entries(store)
  end

  test "idempotency metadata is opaque and keys are independent across routes" do
    legacy =
      Memory.Entry.new!(
        id: "mem_legacy",
        agent_id: "memory_agent",
        content: "User metadata only",
        metadata: %{"idempotency_key" => "same-key"}
      )

    {:ok, pid} = InMemory.start_link(initial_entries: [legacy])
    store = {InMemory, pid: pid}
    agent_route = Memory.Route.new!(kind: :agent, agent_id: "memory_agent")

    namespace_route =
      Memory.Route.new!(
        kind: :namespace,
        agent_id: "memory_agent",
        namespace: "tenant:acme"
      )

    keyed =
      Memory.Entry.new!(
        id: "mem_keyed",
        agent_id: "memory_agent",
        content: "True keyed write"
      )

    assert {:ok, %Memory.WriteResult{entry: agent_entry}} =
             Memory.Store.write(
               store,
               Memory.WriteRequest.new!(
                 entry: keyed,
                 route: agent_route,
                 idempotency_key: "same-key"
               )
             )

    assert agent_entry.content == "True keyed write"

    assert {:ok, %Memory.WriteResult{entry: namespace_entry}} =
             Memory.Store.write(
               store,
               Memory.WriteRequest.new!(
                 entry: keyed,
                 route: namespace_route,
                 idempotency_key: "same-key"
               )
             )

    assert namespace_entry.id != agent_entry.id
    assert {:ok, entries} = Memory.Store.list_entries(store)
    assert Enum.map(entries, & &1.content) == ["User metadata only", "True keyed write", "True keyed write"]

    assert JidoMemory.idempotency_entry_id(agent_route, keyed, "same-key") == agent_entry.id

    assert JidoMemory.idempotency_entry_id(namespace_route, keyed, "same-key") ==
             namespace_entry.id
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

  test "jido_memory store reports the missing optional dependency" do
    store = {JidoMemory, namespace: "jidoka:test"}

    entry =
      Memory.Entry.new!(
        id: "mem_jido",
        agent_id: "memory_agent",
        session_id: "sess_1",
        content: "Ada prefers short answers.",
        metadata: %{"tags" => ["preference"]}
      )

    request = Memory.WriteRequest.new!(entry: entry)
    missing = {:missing_optional_dependency, :jido_memory, :"Elixir.Jido.Memory.Runtime"}

    assert {:error, ^missing} = Memory.Store.write(store, request)

    recall =
      Memory.RecallRequest.new!(
        agent_id: "memory_agent",
        session_id: "sess_1",
        scope: :session,
        query: "How should I answer?",
        limit: 5
      )

    assert {:error, ^missing} = Memory.Store.recall(store, recall)
    assert {:error, ^missing} = Memory.Store.list_entries(store)
  end

  test "jido_memory adapter writes and recalls through injected runtime modules" do
    opts = jido_memory_opts()

    entry =
      Memory.Entry.new!(
        id: "memory-entry",
        agent_id: "memory-agent",
        session_id: "session-1",
        content: "Ada prefers concise answers.",
        metadata: %{
          "class" => :episodic,
          kind: :preference,
          tags: [:answer, "concise"],
          source: "unit-test"
        }
      )

    route = Memory.Route.new!(kind: :session, agent_id: "memory-agent", session_id: "session-1")
    request = Memory.WriteRequest.new!(route: route, entry: entry, idempotency_key: "write-1")

    assert {:ok, write} = JidoMemory.write(request, opts)
    assert write.entry.content == "Ada prefers concise answers."
    assert write.metadata["provider"] == "jido_memory"

    assert_receive {:jido_memory_remember, %{id: "memory-agent"}, attrs, runtime_opts}
    assert attrs.namespace == "agent:memory-agent:session:session-1"
    assert attrs.class == :episodic
    assert attrs.kind == :preference
    assert attrs.tags == ["answer", "concise"]
    assert attrs.source == "unit-test"
    assert runtime_opts[:provider] == :basic
    assert runtime_opts[:provider_opts][:store] == FakeJidoMemoryStore

    Process.put(
      {FakeJidoMemoryRuntime, :records},
      [
        %{
          id: "recalled-text",
          namespace: attrs.namespace,
          class: :semantic,
          kind: :fact,
          text: "Text record",
          content: %{},
          tags: ["text"],
          metadata: %{"jidoka_agent_id" => "memory-agent", "jidoka_session_id" => "session-1"}
        },
        %{
          id: "recalled-content",
          namespace: attrs.namespace,
          class: :semantic,
          kind: :fact,
          text: "",
          content: %{"content" => "String-key content"},
          tags: [],
          metadata: %{}
        },
        %{
          id: "recalled-atom-content",
          namespace: attrs.namespace,
          class: :semantic,
          kind: :fact,
          text: nil,
          content: %{content: "Atom-key content"},
          tags: [],
          metadata: %{}
        },
        %{
          id: "recalled-inspected",
          namespace: attrs.namespace,
          class: :semantic,
          kind: :fact,
          text: nil,
          content: [:raw],
          tags: [],
          metadata: %{}
        }
      ]
    )

    recall =
      Memory.RecallRequest.new!(
        route: route,
        query: "concise",
        limit: 4
      )

    assert {:ok, result} = JidoMemory.recall(recall, Keyword.put(opts, :filter_text?, true))

    assert Enum.map(result.entries, & &1.content) == [
             "Text record",
             "String-key content",
             "Atom-key content",
             "[:raw]"
           ]

    assert result.metadata["total_count"] == 7

    assert_receive {:jido_memory_retrieve, %{id: "memory-agent"}, query, _runtime_opts}
    assert query.text_contains == "concise"
    assert query.order == :desc
  end

  test "jido_memory adapter resolves every list namespace option" do
    Process.put({FakeJidoMemoryRuntime, :records}, [])

    cases = [
      {[list_namespace: "explicit:list"], "explicit:list", "jidoka"},
      {[namespace: "explicit:namespace"], "explicit:namespace", "jidoka"},
      {[agent_id: "agent-1"], "agent:agent-1", "agent-1"},
      {[agent_id: "agent-1", session_id: "session-1"], "agent:agent-1:session:session-1", "agent-1"}
    ]

    Enum.each(cases, fn {list_opts, expected_namespace, expected_target} ->
      assert {:ok, []} = JidoMemory.list_entries(jido_memory_opts() ++ list_opts)

      assert_receive {:jido_memory_retrieve, %{id: ^expected_target}, query, _runtime_opts}
      assert query.namespace == expected_namespace
      assert query.order == :asc
    end)

    assert {:error, :missing_memory_namespace} = JidoMemory.list_entries(jido_memory_opts())
  end

  defp jido_memory_opts do
    [
      runtime: FakeJidoMemoryRuntime,
      retrieve_result: FakeJidoMemoryRetrieveResult,
      default_store: FakeJidoMemoryStore
    ]
  end
end
