defmodule Jidoka.ExecutionEnvironment.ValidatorTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.ExecutionEnvironment.Validator

  @digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  test "validates declared capability and full confirmed evidence" do
    assert :ok = Validator.validate_profile(profile(), capabilities(), request())
    assert :ok = Validator.validate_evidence(profile(), evidence())
  end

  test "each missing declared guarantee fails closed with its dimension" do
    cases = [
      {:adapter_available, %{available: false}},
      {:adapter_identity, %{adapter_id: "other"}},
      {:isolation, %{isolations: []}},
      {:network, %{networks: []}},
      {:workspace, %{workspaces: []}},
      {:image_digest, %{immutable_image_evidence: false}},
      {:limits, %{limit_keys: []}},
      {:checkpoint, %{checkpoint: false}},
      {:fork, %{fork: false}},
      {:capability_ids, %{capability_ids: []}}
    ]

    Enum.each(cases, fn {dimension, changes} ->
      capabilities = struct!(capabilities(), changes)

      assert {:error, %Error{code: :insufficient_adapter_capability, details: %{dimension: ^dimension}}} =
               Validator.validate_profile(profile(), capabilities, request())
    end)
  end

  test "weaker or missing confirmed evidence fails closed with its dimension" do
    cases = [
      {:status, %{status: :partial}},
      {:adapter_identity, %{adapter_id: "other"}},
      {:isolation, %{isolation: :container}},
      {:network, %{network: :restricted}},
      {:workspace, %{workspace: :ephemeral}},
      {:image_digest, %{image_digest: @digest}},
      {:limits, %{applied_limits: %{}}},
      {:limits, %{applied_limits: %{"memory_bytes" => 2_048}}},
      {:checkpoint, %{checkpoint: %{"forkable" => true}}},
      {:fork, %{checkpoint: %{"supported" => true}}}
    ]

    Enum.each(cases, fn {dimension, changes} ->
      evidence = struct!(evidence(), changes)

      assert {:error, %Error{code: :execution_environment_unenforced, details: %{dimension: ^dimension}}} =
               Validator.validate_evidence(profile(), evidence)
    end)
  end

  defp profile do
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
  end

  defp capabilities do
    AdapterCapabilities.new!(
      adapter_id: "test.adapter",
      adapter_version: "1",
      available: true,
      isolations: [:microvm],
      networks: [:disabled],
      workspaces: [:isolated_copy],
      immutable_image_evidence: true,
      limit_keys: ["memory_bytes"],
      checkpoint: true,
      fork: true,
      capability_ids: ["files.read"]
    )
  end

  defp request, do: PolicyRequest.new!(profile_id: "restricted", capability_ids: ["files.read"])

  defp evidence do
    EnforcementEvidence.new!(
      status: :confirmed,
      adapter_id: "test.adapter",
      backend: "test-backend",
      isolation: :microvm,
      network: :disabled,
      workspace: :isolated_copy,
      image_digest: @image_digest,
      applied_limits: %{"memory_bytes" => 1_024},
      checkpoint: %{"supported" => true, "forkable" => true},
      observed_at_ms: 10
    )
  end
end
