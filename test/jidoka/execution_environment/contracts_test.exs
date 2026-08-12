defmodule Jidoka.ExecutionEnvironment.ContractsTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  @digest "sha256:" <> String.duplicate("a", 64)
  @other_digest "sha256:" <> String.duplicate("b", 64)

  test "constructs and JSON-encodes each versioned contract" do
    request = PolicyRequest.new!(profile_id: "restricted", capability_ids: ["files.read"])

    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 2,
        digest: @digest,
        adapter_id: "host.sandbox",
        required_isolation: :microvm,
        required_network: :disabled,
        required_workspace: :isolated_copy,
        required_image_digest: @other_digest,
        maximum_limits: %{"memory_bytes" => 1_024},
        checkpoint_required: true,
        fork_required: true,
        retention: :durable
      )

    binding =
      Binding.new!(
        adapter_id: "host.sandbox",
        adapter_version: "1.2.0",
        profile_id: "restricted",
        profile_digest: @digest,
        resource_ref: "env_123",
        revision: 1,
        state: :available
      )

    evidence =
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "host.sandbox",
        backend: "sandbox-v1",
        isolation: :microvm,
        network: :disabled,
        workspace: :isolated_copy,
        image_digest: @other_digest,
        applied_limits: %{"memory_bytes" => 1_024},
        checkpoint: %{"supported" => true},
        observed_at_ms: 10,
        attestation_ref: "attestation_1"
      )

    checkpoint =
      Checkpoint.new!(
        checkpoint_ref: "checkpoint_1",
        binding_revision: 1,
        profile_digest: @digest,
        evidence_digest: ExecutionEnvironment.digest(evidence),
        preserves: %{"files" => true, "processes" => false},
        forkable: true,
        created_at_ms: 11
      )

    for contract <- [request, profile, binding, evidence, checkpoint] do
      projected = Jidoka.project(contract)
      assert projected["version"] == 1
      assert {:ok, _json} = Jason.encode(projected)
    end
  end

  test "untrusted policy requests reject backend controls and duplicate capabilities" do
    assert {:error, {:unsupported_execution_policy_keys, ["image"]}} =
             PolicyRequest.new(%{profile_id: "restricted", image: "latest"})

    assert {:error, _reason} =
             PolicyRequest.new(profile_id: "restricted", capability_ids: ["files.read", "files.read"])
  end

  test "profiles require immutable image and profile digests and nonnegative limits" do
    attrs = [
      profile_id: "restricted",
      revision: 1,
      digest: @digest,
      adapter_id: "host.sandbox",
      required_isolation: :container,
      required_network: :disabled,
      required_workspace: :ephemeral
    ]

    assert {:error, _reason} = SecurityProfile.new(Keyword.put(attrs, :digest, "mutable-tag"))

    assert {:error, _reason} =
             SecurityProfile.new(Keyword.put(attrs, :maximum_limits, %{memory_bytes: -1}))

    assert {:error, _reason} =
             SecurityProfile.new(Keyword.put(attrs, :required_image_digest, "image:latest"))
  end

  test "bindings and checkpoints reject live values, credentials, and host paths" do
    binding_attrs = [
      adapter_id: "host.sandbox",
      adapter_version: "1",
      profile_id: "restricted",
      profile_digest: @digest,
      resource_ref: "env_123"
    ]

    assert {:error, _reason} = Binding.new(Keyword.put(binding_attrs, :resource_ref, "/tmp/env"))
    assert {:error, reason} = Binding.new(Keyword.put(binding_attrs, :metadata, %{owner: self()}))
    assert inspect(reason) =~ "owner"
    assert inspect(reason) =~ "pid"

    assert {:error, reason} =
             Binding.new(Keyword.put(binding_attrs, :metadata, %{credentials: "do-not-store"}))

    assert inspect(reason) =~ "credential-like"

    checkpoint_attrs = [
      checkpoint_ref: "checkpoint_1",
      binding_revision: 1,
      profile_digest: @digest,
      evidence_digest: @other_digest,
      created_at_ms: 10
    ]

    assert {:error, _reason} =
             Checkpoint.new(Keyword.put(checkpoint_attrs, :preserves, %{adapter: %URI{host: "private"}}))
  end

  test "evidence states unknown and confirmed facts without copying requests" do
    unknown =
      EnforcementEvidence.new!(
        status: :unknown,
        adapter_id: "host.sandbox",
        backend: "unavailable",
        observed_at_ms: 10
      )

    assert unknown.isolation == :unknown
    assert unknown.network == :unknown
    refute Map.has_key?(Jidoka.project(unknown), "profile_id")

    assert {:error, reason} =
             EnforcementEvidence.new(
               status: :confirmed,
               adapter_id: "host.sandbox",
               backend: "sandbox-v1",
               observed_at_ms: 10,
               facts: %{api_key: "secret"}
             )

    assert inspect(reason) =~ "credential-like"
  end

  test "projections omit credential-like provider-private data" do
    value = %{
      "backend" => "sandbox-v1",
      "provider_private" => %{"token" => "secret", "region" => "test"}
    }

    assert ExecutionEnvironment.Contract.project(value) == %{
             "backend" => "sandbox-v1",
             "provider_private" => %{"region" => "test"}
           }
  end
end
