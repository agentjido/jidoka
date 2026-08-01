defmodule Jidoka.HarnessStoreDurabilityTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Harness.LeaseHeartbeat
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.SessionLease
  alias Jidoka.Harness.Store
  alias Jidoka.Harness.Store.Dets
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  test "lease transitions reject stale workers and expose expired recovery work" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    source = Session.start(spec(), session_id: "sess_lease") |> elem(1)
    request = Turn.Request.new!(input: "Run", request_id: "turn_lease")
    assert {:ok, ^source} = Store.put_session(store, source)

    assert {:ok,
            %Session{
              revision: 1,
              status: :running,
              lease: %SessionLease{
                lease_id: "lease_first",
                owner_id: "worker_first",
                expires_at_ms: 150
              }
            } = claimed} =
             Store.claim_session(store, "sess_lease", request,
               clock: fn -> 100 end,
               lease_ttl_ms: 50,
               owner_id: "worker_first",
               id_generator: id_generator("lease_first")
             )

    assert {:error, {:session_lease_required, "sess_lease"}} = Store.put_session(store, source)

    snapshot = snapshot(claimed, "snap_lease")

    assert {:ok,
            %Session{
              revision: 2,
              lease: %SessionLease{lease_id: "lease_first", expires_at_ms: 160}
            }} =
             Store.checkpoint_session(store, "sess_lease", "lease_first", snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 50
             )

    assert {:error, {:stale_session_lease, "sess_lease", "lease_stale"}} =
             Store.checkpoint_session(store, "sess_lease", "lease_stale", snapshot,
               clock: fn -> 120 end,
               lease_ttl_ms: 50
             )

    assert {:ok, []} = Store.list_recoverable(store, clock: fn -> 159 end)

    assert {:ok, [%Session{session_id: "sess_lease"}]} =
             Store.list_recoverable(store, clock: fn -> 160 end)

    assert {:ok,
            %Session{
              revision: 3,
              lease: %SessionLease{lease_id: "lease_second", owner_id: "worker_second"}
            } = recovered} =
             Store.recover_session(store, "sess_lease",
               clock: fn -> 160 end,
               lease_ttl_ms: 50,
               owner_id: "worker_second",
               id_generator: id_generator("lease_second")
             )

    assert {:error, {:stale_session_lease, "sess_lease", "lease_first"}} =
             Store.commit_session(
               store,
               "sess_lease",
               "lease_first",
               Session.put_error(claimed, :stale),
               clock: fn -> 161 end
             )

    assert {:ok, %Session{revision: 4, lease: nil, status: :error, error: :recovered}} =
             Store.commit_session(
               store,
               "sess_lease",
               "lease_second",
               Session.put_error(recovered, :recovered),
               clock: fn -> 161 end
             )
  end

  test "DETS syncs sessions and leases across store process restarts" do
    path = Path.join(System.tmp_dir!(), "jidoka-dets-#{System.unique_integer([:positive])}.dets")
    table = :jidoka_harness_store_durability_test
    on_exit(fn -> File.rm(path) end)

    {:ok, first_pid} = Dets.start_link(path: path, table: table)
    first_store = {Dets, pid: first_pid}
    source = Session.start(spec(), session_id: "sess_dets") |> elem(1)
    request = Turn.Request.new!(input: "Persist", request_id: "turn_dets")

    assert {:ok, ^source} = Store.put_session(first_store, source)

    assert {:ok, %Session{lease: %SessionLease{lease_id: "lease_dets"}} = claimed} =
             Store.claim_session(first_store, "sess_dets", request,
               clock: fn -> 1_000 end,
               lease_ttl_ms: 100,
               owner_id: "worker_dets",
               id_generator: id_generator("lease_dets")
             )

    durable_snapshot = snapshot(claimed, "snap_dets")

    assert {:ok, %Session{revision: 2}} =
             Store.checkpoint_session(first_store, "sess_dets", "lease_dets", durable_snapshot,
               clock: fn -> 1_010 end,
               lease_ttl_ms: 100
             )

    :ok = GenServer.stop(first_pid)

    {:ok, second_pid} = Dets.start_link(path: path, table: table)
    second_store = {Dets, pid: second_pid}

    assert {:ok,
            %Session{
              revision: 2,
              status: :running,
              snapshots: [%AgentSnapshot{snapshot_id: "snap_dets"}]
            }} = Store.get_session(second_store, "sess_dets")

    assert {:ok, [%Session{session_id: "sess_dets"}]} =
             Store.list_recoverable(second_store, clock: fn -> 1_110 end)

    assert {:ok, %Session{lease: %SessionLease{owner_id: "worker_recovery"}}} =
             Store.recover_session(second_store, "sess_dets",
               clock: fn -> 1_110 end,
               lease_ttl_ms: 100,
               owner_id: "worker_recovery",
               id_generator: id_generator("lease_recovery")
             )

    :ok = GenServer.stop(second_pid)
  end

  test "lease heartbeat renews ownership through the store transition" do
    {:ok, clock} = Elixir.Agent.start_link(fn -> 100 end)
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    source = Session.start(spec(), session_id: "sess_heartbeat") |> elem(1)
    request = Turn.Request.new!(input: "Wait", request_id: "turn_heartbeat")
    assert {:ok, ^source} = Store.put_session(store, source)

    assert {:ok, %Session{lease: %SessionLease{lease_id: "lease_heartbeat"}}} =
             Store.claim_session(store, "sess_heartbeat", request,
               clock: current_clock(clock),
               lease_ttl_ms: 50,
               id_generator: id_generator("lease_heartbeat")
             )

    cancellation = Cancellation.Token.new()

    assert {:ok, heartbeat} =
             LeaseHeartbeat.start_link(store, "sess_heartbeat", "lease_heartbeat",
               clock: current_clock(clock),
               lease_ttl_ms: 50,
               lease_heartbeat_interval_ms: 10_000,
               cancellation: cancellation
             )

    Elixir.Agent.update(clock, fn _now -> 140 end)
    send(heartbeat, :renew)
    _state = :sys.get_state(heartbeat)

    assert {:ok,
            %Session{
              revision: 2,
              lease: %SessionLease{lease_id: "lease_heartbeat", expires_at_ms: 190}
            }} = Store.get_session(store, "sess_heartbeat")

    refute Cancellation.requested?(cancellation)
    :ok = GenServer.stop(heartbeat)
  end

  defp snapshot(%Session{} = session, snapshot_id) do
    request = List.last(session.requests)
    plan = Turn.Plan.new!(session.spec)

    Turn.State.new!(
      spec: session.spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
    |> AgentSnapshot.from_turn_state!(Turn.Cursor.after_prompt(), snapshot_id: snapshot_id)
  end

  defp spec do
    Agent.Spec.new!(
      id: "durable_store_agent",
      instructions: "Test durable storage.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp id_generator(id), do: fn "lease" -> id end
  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
