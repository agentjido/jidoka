defmodule Jidoka.SessionMemoryCommitOrderTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Memory
  alias Jidoka.Memory.Store.InMemory, as: MemoryStore
  alias Jidoka.Session
  alias Jidoka.Session.Data
  alias Jidoka.Session.Store
  alias Jidoka.Session.Store.InMemory, as: SessionStore
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule FailingCommitStore do
    @behaviour Jidoka.Session.Store

    alias Jidoka.Session.Store.InMemory

    @impl true
    defdelegate put_session(session, opts), to: InMemory

    @impl true
    defdelegate get_session(session_id, opts), to: InMemory

    @impl true
    defdelegate list_sessions(opts), to: InMemory

    @impl true
    defdelegate claim_session(session_id, request, opts), to: InMemory

    @impl true
    defdelegate claim_resume(session_id, opts), to: InMemory

    @impl true
    defdelegate recover_session(session_id, opts), to: InMemory

    @impl true
    defdelegate checkpoint_session(session_id, lease_id, snapshot, opts), to: InMemory

    @impl true
    def commit_session(_session_id, _lease_id, _session, _opts),
      do: {:error, :forced_session_commit_failure}

    @impl true
    defdelegate renew_session(session_id, lease_id, opts), to: InMemory
  end

  test "a failed session commit does not expose automatic memory capture" do
    {:ok, session_pid} = SessionStore.start_link()
    {:ok, memory_pid} = MemoryStore.start_link()
    session_store = {FailingCommitStore, pid: session_pid}
    memory_store = {MemoryStore, pid: memory_pid}

    assert {:ok, %Data{}} =
             Session.start(capture_spec(), "failed-memory-commit", store: session_store)

    assert {:error, :forced_session_commit_failure} =
             Session.run("failed-memory-commit", "Do not capture",
               store: session_store,
               memory_store: memory_store,
               request_id: "failed-memory-request",
               llm: final_llm("not committed"),
               lease_heartbeat: false,
               clock: fn -> 100 end,
               lease_ttl_ms: 100
             )

    assert {:ok, []} = Memory.Store.list_entries(memory_store)

    assert {:ok, stored} = Store.get_session(session_store, "failed-memory-commit")
    assert stored.conversation.turn_count == 0
    assert stored.conversation.agent_state.messages == []
  end

  test "crash recovery captures one idempotent memory record after commit" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 100 end)
    {:ok, session_pid} = SessionStore.start_link()
    {:ok, memory_pid} = MemoryStore.start_link()
    session_store = {SessionStore, pid: session_pid}
    memory_store = {MemoryStore, pid: memory_pid}

    assert {:ok, %Data{}} =
             Session.start(capture_spec(), "recovered-memory", store: session_store)

    checkpoint_hook = fn stage, %Snapshot{} = snapshot, _stored ->
      if stage == :result and snapshot.cursor.metadata["effect_kind"] == :operation do
        send(test_pid, :operation_result_durable)

        receive do
          :release_crashed_worker -> :ok
        end
      else
        :ok
      end
    end

    worker =
      Task.async(fn ->
        Session.run("recovered-memory", "Look up the account",
          store: session_store,
          memory_store: memory_store,
          request_id: "recovered-memory-request",
          llm: tool_llm(),
          operations: operations(),
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "first-worker",
          on_durable_checkpoint: checkpoint_hook
        )
      end)

    assert_receive :operation_result_durable, 1_000
    assert nil == Task.shutdown(worker, :brutal_kill)
    assert {:ok, []} = Memory.Store.list_entries(memory_store)

    Elixir.Agent.update(clock, fn _now -> 200 end)

    assert {:ok, completed, %Turn.Result{content: "Account acct-1 is active."} = result} =
             Session.recover("recovered-memory",
               store: session_store,
               memory_store: memory_store,
               llm: tool_llm(),
               operations: operations_must_not_repeat(),
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "recovery-worker"
             )

    assert completed.conversation.turn_count == 1
    assert completed.conversation.agent_state.messages != []
    assert {:ok, [entry]} = Memory.Store.list_entries(memory_store)

    expected_id =
      Jidoka.Id.stable("mem", [
        completed.spec.id,
        completed.session_id,
        "recovered-memory-request",
        :conversation
      ])

    assert entry.id == expected_id
    refute Map.has_key?(entry.metadata, "idempotency_key")

    request = List.last(completed.requests)

    assert {:ok, %Memory.WriteResult{entry: %{id: ^expected_id}}} =
             Memory.capture_turn(completed.spec, request, result,
               memory_store: memory_store,
               session_id: completed.session_id
             )

    assert {:ok, [%{id: ^expected_id}]} = Memory.Store.list_entries(memory_store)
  end

  defp capture_spec do
    Agent.Spec.new!(
      id: "commit_order_memory_agent",
      instructions: "Use lookup_account, then answer.",
      model: %{provider: :test, id: "model"},
      memory: %{scope: :session, capture: :conversation},
      operations: [
        Operation.new!(
          name: "lookup_account",
          description: "Looks up one account.",
          idempotency: :idempotent
        )
      ],
      runtime_defaults: %{max_model_turns: 3}
    )
  end

  defp final_llm(content) do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: content}} end
  end

  defp tool_llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_account",
             arguments: %{"account_id" => "acct-1"}
           }}

        _count ->
          {:ok, %{type: :final, content: "Account acct-1 is active."}}
      end
    end
  end

  defp operations do
    Jidoka.Runtime.LocalOperations.operations(%{
      lookup_account: fn _intent, _journal, _context ->
        {:ok, %{"account_id" => "acct-1", "status" => "active"}}
      end
    })
  end

  defp operations_must_not_repeat do
    fn _intent, _journal, _context -> flunk("recovery repeated the completed operation") end
  end

  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
