defmodule Jidoka.ExecutionEnvironment.ManagerTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.Manager
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Policy.Decision

  @digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  defmodule FakeAdapter do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    alias Jidoka.ExecutionEnvironment
    alias Jidoka.ExecutionEnvironment.Binding
    alias Jidoka.ExecutionEnvironment.Checkpoint

    @impl true
    def open(profile, _request, opts) do
      record(opts, :open)

      binding =
        Binding.new!(
          adapter_id: profile.adapter_id,
          adapter_version: "1",
          profile_id: profile.profile_id,
          profile_digest: profile.digest,
          resource_ref: "environment-1",
          revision: 0,
          state: :available
        )

      {:ok, binding, evidence(opts)}
    end

    @impl true
    def acquire(binding, opts) do
      record(opts, :acquire)

      if Keyword.get(opts, :weak_acquire_evidence, false) do
        {:ok, %{resource_ref: binding.resource_ref}, %{evidence(opts) | status: :partial}}
      else
        {:ok, %{resource_ref: binding.resource_ref}, evidence(opts)}
      end
    end

    @impl true
    def checkpoint(_handle, %Binding{} = binding, opts) do
      record(opts, :checkpoint)

      if Keyword.get(opts, :fail_checkpoint, false) do
        {:error, :checkpoint_failed}
      else
        updated = %Binding{binding | revision: binding.revision + 1}

        checkpoint =
          Checkpoint.new!(
            checkpoint_ref: "checkpoint-#{updated.revision}",
            binding_revision: updated.revision,
            profile_digest: binding.profile_digest,
            evidence_digest: ExecutionEnvironment.digest(evidence(opts)),
            preserves: %{"files" => true},
            forkable: true,
            created_at_ms: 11
          )

        {:ok, updated, checkpoint, evidence(opts)}
      end
    end

    @impl true
    def restore(%Binding{} = binding, _checkpoint, opts) do
      record(opts, :restore)
      {:ok, %Binding{binding | resource_ref: "environment-restored", revision: binding.revision + 1}, evidence(opts)}
    end

    @impl true
    def fork(%Binding{} = binding, _checkpoint, opts) do
      record(opts, :fork)
      child = %Binding{binding | resource_ref: "environment-child", revision: 0}

      child_checkpoint =
        Checkpoint.new!(
          checkpoint_ref: "checkpoint-child",
          binding_revision: 0,
          profile_digest: binding.profile_digest,
          evidence_digest: ExecutionEnvironment.digest(evidence(opts)),
          preserves: %{"files" => true},
          forkable: true,
          created_at_ms: 12
        )

      {:ok, child, child_checkpoint, evidence(opts)}
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
        adapter_id: "test.adapter",
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

    defp record(opts, event) do
      Agent.update(Keyword.fetch!(opts, :probe), &[event | &1])
    end
  end

  test "runs the full lifecycle, rotates restore identity, forks immutably, and cleans once" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, manager} = Manager.start_link(registration(), allow_policy(probe), probe: probe)
    request = PolicyRequest.new!(profile_id: "restricted", capability_ids: ["files.read"])

    assert {:ok, binding, %EnforcementEvidence{status: :confirmed}} = Manager.open(manager, request)
    assert {:ok, handle, _evidence} = Manager.acquire(manager, binding)
    assert {:error, %Error{}} = Manager.acquire(manager, binding)

    assert {:ok, updated, checkpoint, _evidence} = Manager.checkpoint(manager, handle, binding)
    assert updated.revision == 1
    assert checkpoint.binding_revision == 1
    assert {:ok, _evidence} = Manager.close(manager, handle)

    assert {:ok, restored, _evidence} = Manager.restore(manager, updated, checkpoint)
    assert restored.resource_ref == "environment-restored"

    assert {:ok, child, child_checkpoint, _evidence} = Manager.fork(manager, updated, checkpoint)
    assert child.resource_ref == "environment-child"
    assert child_checkpoint.forkable

    assert {:ok, cleanup_evidence} = Manager.cleanup(manager, restored)
    assert {:ok, ^cleanup_evidence} = Manager.cleanup(manager, restored)

    events = probe |> Agent.get(&Enum.reverse/1)
    assert events == [:open, :acquire, :checkpoint, :close, :restore, :fork, :cleanup]
    assert Enum.count(events, &(&1 == :cleanup)) == 1
  end

  test "with_acquired closes after success and callback failure" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, manager} = Manager.start_link(registration(), allow_policy(probe), probe: probe)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: "restricted"))

    assert {:ok, :worked, _evidence} = Manager.with_acquired(manager, binding, fn _handle -> :worked end)

    assert {:error, %RuntimeError{message: "failed"}} =
             Manager.with_acquired(manager, binding, fn _handle -> raise "failed" end)

    assert Enum.count(Agent.get(probe, & &1), &(&1 == :close)) == 2
  end

  test "weak acquire evidence and checkpoint failures close transient handles" do
    {:ok, probe} = Agent.start_link(fn -> [] end)

    {:ok, manager} =
      Manager.start_link(registration(), allow_policy(probe), probe: probe, weak_acquire_evidence: true)

    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: "restricted"))
    assert {:error, %Error{}} = Manager.acquire(manager, binding)
    assert [:open, :acquire, :close] = probe |> Agent.get(&Enum.reverse/1)

    {:ok, probe2} = Agent.start_link(fn -> [] end)
    {:ok, manager2} = Manager.start_link(registration(), allow_policy(probe2), probe: probe2)
    {:ok, binding2, _evidence} = Manager.open(manager2, PolicyRequest.new!(profile_id: "restricted"))
    {:ok, handle2, _evidence} = Manager.acquire(manager2, binding2)

    assert {:error, %Error{}} = Manager.checkpoint(manager2, handle2, binding2, fail_checkpoint: true)
    assert [:open, :acquire, :checkpoint, :close] = probe2 |> Agent.get(&Enum.reverse/1)
    assert {:error, %Error{}} = Manager.close(manager2, handle2)
  end

  test "policy denial prevents adapter calls" do
    {:ok, probe} = Agent.start_link(fn -> [] end)

    deny = fn _request, _context ->
      {:ok, Decision.new!(outcome: :deny, rule_id: "host.deny")}
    end

    {:ok, manager} = Manager.start_link(registration(), deny, probe: probe)
    assert {:error, %Error{}} = Manager.open(manager, PolicyRequest.new!(profile_id: "restricted"))
    assert Agent.get(probe, & &1) == []
  end

  test "rejects mismatched, stale, cleaned, and nonforkable data" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, manager} = Manager.start_link(registration(), allow_policy(probe), probe: probe)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: "restricted"))
    {:ok, handle, _evidence} = Manager.acquire(manager, binding)

    {:ok, %Binding{} = updated, %Checkpoint{} = checkpoint, _evidence} =
      Manager.checkpoint(manager, handle, binding)

    {:ok, _evidence} = Manager.close(manager, handle)

    bad_checkpoint = %Checkpoint{checkpoint | binding_revision: 99}
    assert {:error, %Error{}} = Manager.restore(manager, updated, bad_checkpoint)
    assert {:error, %Error{}} = Manager.fork(manager, updated, %Checkpoint{checkpoint | forkable: false})

    assert {:ok, _evidence} = Manager.cleanup(manager, updated)
    assert {:error, %Error{}} = Manager.acquire(manager, updated)
  end

  defp registration do
    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 1,
        digest: @digest,
        adapter_id: "test.adapter",
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
        adapter_id: "test.adapter",
        adapter_version: "1",
        isolations: [:microvm],
        networks: [:disabled],
        workspaces: [:isolated_copy],
        immutable_image_evidence: true,
        limit_keys: ["memory_bytes"],
        checkpoint: true,
        fork: true,
        capability_ids: ["files.read"]
      )

    Registration.new!(profile: profile, adapter: FakeAdapter, capabilities: capabilities)
  end

  defp allow_policy(_probe) do
    fn _request, _context ->
      {:ok, Decision.new!(outcome: :allow, rule_id: "host.allow")}
    end
  end
end
