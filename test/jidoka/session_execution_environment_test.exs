defmodule Jidoka.SessionExecutionEnvironmentTest do
  use ExUnit.Case, async: false

  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.Manager
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Policy.Decision
  alias Jidoka.Session.Data
  alias Jidoka.Session.Environment
  alias Jidoka.Session.Store
  alias Jidoka.Session.Store.Dets
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Snapshot
  alias Jidoka.Turn

  @profile_digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  defmodule Adapter do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    alias Jidoka.ExecutionEnvironment
    alias Jidoka.ExecutionEnvironment.Binding
    alias Jidoka.ExecutionEnvironment.Checkpoint
    alias Jidoka.ExecutionEnvironment.EnforcementEvidence

    @impl true
    def open(profile, _request, opts) do
      record(opts, :open)

      binding =
        Binding.new!(
          adapter_id: profile.adapter_id,
          adapter_version: "1",
          profile_id: profile.profile_id,
          profile_digest: profile.digest,
          resource_ref: "environment-source",
          state: :available
        )

      {:ok, binding, evidence(opts)}
    end

    @impl true
    def acquire(binding, opts) do
      record(opts, :acquire)
      {:ok, %{resource_ref: binding.resource_ref}, evidence(opts)}
    end

    @impl true
    def checkpoint(_handle, %Binding{} = binding, opts) do
      record(opts, :checkpoint)
      binding = %Binding{binding | revision: binding.revision + 1}

      checkpoint =
        Checkpoint.new!(
          checkpoint_ref: "checkpoint-#{binding.revision}",
          binding_revision: binding.revision,
          profile_digest: binding.profile_digest,
          evidence_digest: ExecutionEnvironment.digest(evidence(opts)),
          preserves: %{"files" => true},
          forkable: true,
          created_at_ms: 10
        )

      {:ok, binding, checkpoint, evidence(opts)}
    end

    @impl true
    def restore(%Binding{} = binding, _checkpoint, opts) do
      record(opts, :restore)

      {:ok,
       %Binding{
         binding
         | resource_ref: "environment-restored",
           revision: binding.revision + 1
       }, evidence(opts)}
    end

    @impl true
    def fork(%Binding{} = binding, _checkpoint, opts) do
      record(opts, :fork)
      child = %Binding{binding | resource_ref: "environment-child", revision: 0}

      checkpoint =
        Checkpoint.new!(
          checkpoint_ref: "checkpoint-child",
          binding_revision: 0,
          profile_digest: child.profile_digest,
          evidence_digest: ExecutionEnvironment.digest(evidence(opts)),
          preserves: %{"files" => true},
          forkable: true,
          created_at_ms: 11
        )

      {:ok, child, checkpoint, evidence(opts)}
    end

    @impl true
    def close(_handle, opts) do
      record(opts, :close)
      {:ok, evidence(opts)}
    end

    @impl true
    def cleanup(_binding, opts) do
      record(opts, :cleanup)
      {:ok, evidence(opts)}
    end

    defp evidence(opts) do
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "test.session-adapter",
        backend: "test-backend",
        isolation: :microvm,
        network: :disabled,
        workspace: :isolated_copy,
        image_digest: "sha256:" <> String.duplicate("b", 64),
        applied_limits: %{"memory_bytes" => 1_024},
        checkpoint: %{"supported" => true, "forkable" => true},
        observed_at_ms: Keyword.get(opts, :observed_at_ms, 10)
      )
    end

    defp record(opts, event), do: Agent.update(Keyword.fetch!(opts, :probe), &[event | &1])
  end

  test "opens, acquires, closes, and cleans an ephemeral session environment" do
    {manager, probe, request} = runtime()
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}
    environment = runtime_opts(manager, request, :ephemeral)

    assert {:ok, %Data{environment: %Environment{status: :opened}}} =
             Jidoka.Session.start(spec(), "session-ephemeral",
               store: store,
               execution_environment: environment
             )

    assert {:ok, %Data{environment: %Environment{status: :cleaned}} = finished, %Turn.Result{}} =
             Jidoka.Session.run("session-ephemeral", "Hello",
               store: store,
               execution_environment: environment,
               llm: final_llm()
             )

    assert finished.environment.binding.resource_ref == "environment-source"

    assert events(probe) == [
             :open,
             :acquire,
             :checkpoint,
             :checkpoint,
             :checkpoint,
             :close,
             :cleanup
           ]

    assert {:error, {:execution_environment_cleaned, "environment-source"}} =
             Jidoka.Session.run("session-ephemeral", "Again",
               store: store,
               execution_environment: environment,
               llm: final_llm()
             )

    assert events(probe) == [
             :open,
             :acquire,
             :checkpoint,
             :checkpoint,
             :checkpoint,
             :close,
             :cleanup
           ]
  end

  test "stores a turn snapshot and its environment checkpoint in one revision" do
    {manager, _probe, request} = runtime()
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}
    environment_opts = runtime_opts(manager, request, :durable)

    {:ok, source} =
      Jidoka.Session.start(spec(), "session-atomic",
        store: store,
        execution_environment: environment_opts
      )

    turn_request = Turn.Request.new!(input: "Checkpoint", request_id: "turn-atomic")

    {:ok, claimed} =
      Store.claim_session(store, source.session_id, turn_request,
        clock: fn -> 100 end,
        lease_ttl_ms: 100,
        owner_id: "worker",
        id_generator: fn "lease" -> "lease-atomic" end
      )

    {:ok, _session, runtime_opts, lease} =
      Jidoka.Session.EnvironmentRuntime.acquire(claimed,
        execution_environment: environment_opts
      )

    assert {:ok, %Environment{checkpoint: %Checkpoint{} = checkpoint} = environment} =
             Jidoka.Session.EnvironmentRuntime.checkpoint(runtime_opts)

    snapshot =
      Snapshot.from_turn_state!(turn_state(source.spec, turn_request), Turn.Cursor.after_prompt(),
        snapshot_id: "snapshot-atomic",
        environment: environment
      )

    assert {:ok,
            %Data{
              revision: 2,
              environment: %Environment{checkpoint: ^checkpoint},
              snapshots: [%Snapshot{environment: %Environment{checkpoint: ^checkpoint}}]
            }} =
             Store.checkpoint_session(store, source.session_id, "lease-atomic", snapshot,
               clock: fn -> 110 end,
               lease_ttl_ms: 100
             )

    assert {:ok, %Environment{}} =
             Jidoka.Session.EnvironmentRuntime.finish(lease, :hibernated, runtime_opts)
  end

  test "DETS keeps portable environment data and old sessions still run" do
    {manager, _probe, request} = runtime()
    environment_opts = runtime_opts(manager, request, :durable)
    path = Path.join(System.tmp_dir!(), "jidoka-environment-#{System.unique_integer([:positive])}.dets")
    table = :jidoka_session_execution_environment_test
    on_exit(fn -> File.rm(path) end)

    {:ok, first_pid} = Dets.start_link(path: path, table: table)
    first_store = {Dets, pid: first_pid}

    assert {:ok, %Data{environment: %Environment{} = environment}} =
             Jidoka.Session.start(spec(), "session-dets",
               store: first_store,
               execution_environment: environment_opts
             )

    :ok = GenServer.stop(first_pid)
    {:ok, second_pid} = Dets.start_link(path: path, table: table)
    second_store = {Dets, pid: second_pid}
    assert {:ok, %Data{environment: ^environment}} = Store.get_session(second_store, "session-dets")
    :ok = GenServer.stop(second_pid)

    assert {:ok, %Data{} = old_session} = Data.start(spec(), session_id: "old-session")
    old_session = %Data{old_session | schema_version: 1}

    assert {:ok, %Data{environment: nil, status: :finished}, %Turn.Result{}} =
             Jidoka.Session.run(old_session, "Hello", llm: final_llm())
  end

  test "recovery restores once before acquire and fork keeps the source unchanged" do
    {manager, probe, request} = runtime()
    environment_opts = runtime_opts(manager, request, :durable)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    {:ok, source} =
      Jidoka.Session.start(spec(), "session-recovery",
        store: store,
        execution_environment: environment_opts
      )

    {:ok, _source, runtime_opts, lease} =
      Jidoka.Session.EnvironmentRuntime.acquire(source,
        execution_environment: environment_opts
      )

    {:ok, checkpointed_environment} = Jidoka.Session.EnvironmentRuntime.checkpoint(runtime_opts)
    {:ok, _environment} = Jidoka.Session.EnvironmentRuntime.finish(lease, :hibernated, runtime_opts)
    source = Data.put_environment(source, checkpointed_environment)
    {:ok, ^source} = Store.put_session(store, source)

    turn_request = Turn.Request.new!(input: "Recover", request_id: "turn-recovery")

    {:ok, _claimed} =
      Store.claim_session(store, source.session_id, turn_request,
        clock: fn -> 100 end,
        lease_ttl_ms: 10,
        owner_id: "first",
        id_generator: fn "lease" -> "lease-first" end
      )

    snapshot =
      Snapshot.from_turn_state!(turn_state(source.spec, turn_request), Turn.Cursor.after_prompt(),
        snapshot_id: "snapshot-recovery",
        environment: checkpointed_environment
      )

    assert {:ok, %Data{environment: %Environment{status: :available}} = recovered, %Turn.Result{}} =
             Jidoka.Session.recover(source.session_id,
               store: store,
               execution_environment: environment_opts,
               llm: final_llm(),
               clock: fn -> 111 end,
               lease_ttl_ms: 10,
               lease_heartbeat: false,
               owner_id: "second",
               id_generator: fn prefix -> "#{prefix}-recovery" end
             )

    assert recovered.environment.binding.resource_ref == "environment-restored"
    assert Enum.count(events(probe), &(&1 == :restore)) == 1

    assert Enum.take(events(probe), -6) == [
             :restore,
             :acquire,
             :checkpoint,
             :checkpoint,
             :checkpoint,
             :close
           ]

    source_for_fork =
      source
      |> Data.put_environment(checkpointed_environment)
      |> Data.put_snapshot(snapshot)

    assert {:ok, %Data{environment: %Environment{status: :forked}} = child} =
             Jidoka.Session.fork(source_for_fork,
               session_id: "session-child",
               execution_environment: environment_opts,
               id_generator: fn
                 "snap" -> "snapshot-child"
                 "sess" -> "session-child"
               end
             )

    assert child.environment.binding.resource_ref == "environment-child"
    assert source_for_fork.environment.binding.resource_ref == "environment-source"
    assert source_for_fork.environment.checkpoint.checkpoint_ref == "checkpoint-1"
  end

  defp runtime do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, manager} = Manager.start_link(registration(), allow_policy(), probe: probe)
    {manager, probe, PolicyRequest.new!(profile_id: "restricted")}
  end

  defp runtime_opts(manager, request, retention) do
    %{manager: manager, request: request, retention: retention}
  end

  defp registration do
    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 1,
        digest: @profile_digest,
        adapter_id: "test.session-adapter",
        required_isolation: :microvm,
        required_network: :disabled,
        required_workspace: :isolated_copy,
        required_image_digest: @image_digest,
        maximum_limits: %{"memory_bytes" => 1_024},
        checkpoint_required: true,
        fork_required: true,
        retention: :durable
      )

    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.session-adapter",
        adapter_version: "1",
        isolations: [:microvm],
        networks: [:disabled],
        workspaces: [:isolated_copy],
        immutable_image_evidence: true,
        limit_keys: ["memory_bytes"],
        checkpoint: true,
        fork: true
      )

    Registration.new!(profile: profile, adapter: Adapter, capabilities: capabilities)
  end

  defp allow_policy do
    fn _request, _context ->
      {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")}
    end
  end

  defp final_llm do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: "done"}} end
  end

  defp spec do
    Jidoka.agent!(
      id: "session_environment_agent",
      instructions: "Test durable execution environments.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp turn_state(spec, request) do
    Turn.State.new!(
      spec: spec,
      plan: Turn.Plan.new!(spec),
      request: request,
      agent_state: request.agent_state
    )
  end

  defp events(probe), do: probe |> Agent.get(&Enum.reverse/1)
end
