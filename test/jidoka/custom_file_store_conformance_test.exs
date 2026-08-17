defmodule Jidoka.CustomFileStoreConformanceTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Session.Data
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Store
  alias Jidoka.Snapshot
  alias Jidoka.TestSupport.FileSessionStore
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2, final_llm: 1]

  setup do
    path = Path.join(System.tmp_dir!(), "jidoka-custom-store-#{System.unique_integer([:positive])}.bin")

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".next")
    end)

    %{path: path}
  end

  test "the public transition set commits lease and checkpoint identities", %{path: path} do
    {pid, store} = start_store(path)
    source = start_data("custom-lifecycle")
    request = Turn.Request.new!(input: "Persist", request_id: "request-lifecycle")

    assert {:ok, ^source} = Store.put_session(store, source)

    assert {:ok, %Data{revision: 1, lease: %Lease{lease_id: "lease-one"}} = claimed} =
             Store.claim_session(store, source.session_id, request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker-one",
               id_generator: id_generator("lease-one")
             )

    snapshot = snapshot(claimed, "snapshot-lifecycle")

    assert {:ok, %Data{revision: 2} = checkpointed} =
             Store.checkpoint_session(store, source.session_id, "lease-one", snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    assert {:ok,
            %{
              session_id: "custom-lifecycle",
              durable_revision: 2,
              request_id: "request-lifecycle",
              lease_id: "lease-one",
              snapshot_id: "snapshot-lifecycle"
            }} = Store.checkpoint_identity(checkpointed, snapshot)

    uncommitted = %Snapshot{snapshot | snapshot_id: "snapshot-uncommitted"}

    assert {:error,
            {:checkpoint_identity_not_committed, "custom-lifecycle", 2, "request-lifecycle", "lease-one",
             "snapshot-uncommitted"}} = Store.checkpoint_identity(checkpointed, uncommitted)

    assert {:ok, %Data{revision: 3, lease: %Lease{expires_at_ms: 170}}} =
             Store.renew_session(store, source.session_id, "lease-one",
               clock: fn -> 120 end,
               lease_ttl_ms: 50
             )

    GenServer.stop(pid)

    {restarted_pid, restarted_store} = start_store(path)

    assert {:ok, %Data{revision: 3, snapshots: [%Snapshot{snapshot_id: "snapshot-lifecycle"}]}} =
             Store.get_session(restarted_store, source.session_id)

    assert {:ok, %Data{revision: 4, lease: %Lease{lease_id: "lease-two"}} = recovered} =
             Store.recover_session(restarted_store, source.session_id,
               clock: fn -> 170 end,
               lease_ttl_ms: 50,
               owner_id: "worker-two",
               id_generator: id_generator("lease-two")
             )

    assert {:error, {:stale_session_lease, "custom-lifecycle", "lease-one"}} =
             Store.commit_session(
               restarted_store,
               source.session_id,
               "lease-one",
               Data.put_error(recovered, :stale),
               clock: fn -> 171 end
             )

    assert {:ok, %Data{revision: 5, lease: nil, status: :error}} =
             Store.commit_session(
               restarted_store,
               source.session_id,
               "lease-two",
               Data.put_error(recovered, :recovered),
               clock: fn -> 171 end
             )

    GenServer.stop(restarted_pid)
  end

  test "a synced transition survives a store crash before its reply", %{path: path} do
    test_pid = self()
    {pid, store} = start_store(path)
    Process.unlink(pid)

    source = start_data("custom-crash-before-reply")
    request = Turn.Request.new!(input: "Commit before reply", request_id: "request-crash")
    assert {:ok, ^source} = Store.put_session(store, source)

    store_ref = Process.monitor(pid)

    {caller, caller_ref} =
      spawn_monitor(fn ->
        Store.claim_session(store, source.session_id, request,
          clock: fn -> 200 end,
          lease_ttl_ms: 50,
          owner_id: "crash-worker",
          id_generator: id_generator("lease-crash"),
          test_pid: test_pid,
          crash_after_sync: true
        )
      end)

    assert_receive {:file_session_store_synced, :claim, %Data{revision: 1}}, 1_000
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, _reason}, 1_000
    assert_receive {:DOWN, ^store_ref, :process, ^pid, :killed}, 1_000

    {restarted_pid, restarted_store} = start_store(path)

    assert {:ok,
            %Data{
              revision: 1,
              status: :running,
              lease: %Lease{lease_id: "lease-crash", request_id: "request-crash"}
            }} = Store.get_session(restarted_store, source.session_id)

    GenServer.stop(restarted_pid)
  end

  test "the file store resumes and forks through public session APIs", %{path: path} do
    {pid, store} = start_store(path)

    assert {:ok, %Data{}} = Jidoka.Session.start(chat_spec(), "custom-fork-source", store: store)

    assert {:hibernate, source, %Snapshot{} = snapshot} =
             Jidoka.Session.run("custom-fork-source", "Choose a path",
               store: store,
               request_id: "request-fork",
               llm: final_llm("unused"),
               checkpoint: :after_prompt
             )

    assert {:ok, branch} =
             Jidoka.Session.fork("custom-fork-source",
               store: store,
               session_id: "custom-fork-branch",
               fork_snapshot_id: "snapshot-fork-branch",
               clock: fn -> 300 end
             )

    assert branch.lineage.source_snapshot_id == snapshot.snapshot_id
    assert {:ok, ^source} = Store.get_session(store, "custom-fork-source")

    assert {:ok, source_finished, %Turn.Result{content: "source path"}} =
             Jidoka.Session.resume("custom-fork-source", store: store, llm: final_llm("source path"))

    assert {:ok, branch_finished, %Turn.Result{content: "branch path"}} =
             Jidoka.Session.resume("custom-fork-branch", store: store, llm: final_llm("branch path"))

    assert source_finished.session_id == "custom-fork-source"
    assert branch_finished.session_id == "custom-fork-branch"
    GenServer.stop(pid)
  end

  test "the file store preserves an unsafe intent and recovery does not repeat it", %{path: path} do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 1_000 end)
    {pid, store} = start_store(path)

    assert {:ok, %Data{}} = Jidoka.Session.start(unsafe_spec(), "custom-unsafe", store: store)

    operations =
      LocalOperations.operations(%{
        refund_order: fn _intent, _journal, _context ->
          send(test_pid, {:unsafe_operation_started, self()})

          receive do
            :finish -> {:ok, %{"refund_id" => "unexpected"}}
          end
        end
      })

    worker =
      Task.async(fn ->
        Jidoka.Session.run("custom-unsafe", "Refund order_123",
          store: store,
          llm: unsafe_llm(),
          operations: operations,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "unsafe-worker-one"
        )
      end)

    assert_receive {:unsafe_operation_started, operation_pid}, 1_000
    operation_ref = Process.monitor(operation_pid)
    assert nil == Task.shutdown(worker, :brutal_kill)
    assert_receive {:DOWN, ^operation_ref, :process, ^operation_pid, _reason}, 1_000

    assert {:ok, %Data{status: :running, snapshots: snapshots}} = Store.get_session(store, "custom-unsafe")
    assert incomplete_unsafe_intent?(List.last(snapshots))

    Elixir.Agent.update(clock, fn _now -> 1_100 end)

    assert {:error,
            %ExecutionError{
              phase: :effect,
              details: %{reason: :unsafe_once_incomplete_effect, idempotency: :unsafe_once}
            }} =
             Jidoka.Session.recover("custom-unsafe",
               store: store,
               llm: unsafe_llm(),
               operations: fn _intent, _journal, _context ->
                 send(test_pid, :unsafe_operation_repeated)
                 {:ok, %{}}
               end,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "unsafe-worker-two"
             )

    refute_received :unsafe_operation_repeated
    GenServer.stop(pid)
  end

  test "durable schema and codec documents match the public accessors" do
    session_version = Data.schema_version()
    session_supported = inspect(Data.supported_schema_versions())
    snapshot_version = Snapshot.schema_version()
    snapshot_supported = inspect(Snapshot.supported_schema_versions())
    prefix = Snapshot.serialization_prefix()

    sessions = guide("sessions-and-stores.md")
    snapshots = guide("runtime-capabilities-internals.md")
    durability = guide("runtime-and-harness.md")

    assert sessions =~ "`schema_version/0` is `#{session_version}`"
    assert sessions =~ "`supported_schema_versions/0` is `#{session_supported}`"
    assert snapshots =~ "`Jidoka.Snapshot.schema_version/0` returns `#{snapshot_version}`"
    assert snapshots =~ "`supported_schema_versions/0` returns `#{snapshot_supported}`"
    assert durability =~ "`Jidoka.Snapshot.schema_version() == #{snapshot_version}`"
    assert durability =~ "`Jidoka.Snapshot.serialization_prefix() == \"#{prefix}\"`"
    assert durability =~ "`Jidoka.Session.Data.schema_version() == #{session_version}`"
  end

  defp start_store(path) do
    {:ok, pid} = FileSessionStore.start_link(path: path)
    {pid, {FileSessionStore, pid: pid}}
  end

  defp start_data(session_id) do
    {:ok, session} = Data.start(chat_spec(), session_id: session_id)
    session
  end

  defp snapshot(%Data{} = session, snapshot_id) do
    request = List.last(session.requests)

    Turn.State.new!(
      spec: session.spec,
      plan: Turn.Plan.new!(session.spec),
      request: request,
      agent_state: request.agent_state
    )
    |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end

  defp chat_spec do
    Agent.Spec.new!(
      id: "custom_file_store_agent",
      instructions: "Test the public durable store contract.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp unsafe_spec do
    Agent.Spec.new!(
      id: "custom_file_store_unsafe_agent",
      instructions: "Use refund_order, then report the result.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "refund_order",
          description: "Starts one refund.",
          idempotency: :unsafe_once
        )
      ],
      controls:
        Controls.new!(
          operations: [
            %{control: Jidoka.IntegrationSupport.ApprovalControl, match: %{name: "refund_order"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp unsafe_llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => "order_123"}
           }}

        _count ->
          {:ok, %{type: :final, content: "Refund complete."}}
      end
    end
  end

  defp incomplete_unsafe_intent?(%Snapshot{} = snapshot) do
    Enum.any?(snapshot.turn_state.journal.intents, fn {_id, intent} ->
      intent.kind == :operation and intent.idempotency == :unsafe_once and
        is_nil(Effect.Journal.result_for(snapshot.turn_state.journal, intent))
    end)
  end

  defp guide(name), do: File.read!(Path.expand("../../guides/#{name}", __DIR__))
  defp id_generator(id), do: fn "lease" -> id end
  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
