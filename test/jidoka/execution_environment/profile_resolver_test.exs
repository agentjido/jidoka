defmodule Jidoka.ExecutionEnvironment.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.ProfileResolver
  alias Jidoka.ExecutionEnvironment.ProfileResolver.InMemory
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  @digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  defmodule FakeAdapter do
  end

  test "resolves one complete trusted profile with a stable safe fingerprint" do
    registration = registration()
    assert {:ok, resolver} = InMemory.new([registration])
    request = PolicyRequest.new!(profile_id: "restricted", capability_ids: ["files.read"])

    assert {:ok, resolved} = ProfileResolver.resolve(request, InMemory.resolver(resolver))
    assert resolved.registration.profile.profile_id == "restricted"
    assert resolved.registration.adapter == FakeAdapter
    assert String.starts_with?(resolved.fingerprint, "sha256:")
    refute inspect(Jidoka.project(resolved)) =~ "FakeAdapter"
  end

  test "unknown, disabled, duplicate, malformed, and failed resolvers are typed" do
    request = PolicyRequest.new!(profile_id: "restricted")

    assert {:error, %Error{code: :unknown_profile}} =
             ProfileResolver.resolve(request, fn _id, _opts -> {:error, :unknown_profile} end)

    disabled = registration(enabled: false)
    assert {:ok, resolver} = InMemory.new([disabled])

    assert {:error, %Error{code: :disabled_profile}} =
             ProfileResolver.resolve(request, InMemory.resolver(resolver))

    assert {:error, :ambiguous_profile_registration} =
             InMemory.new([registration(), registration()])

    assert {:error, %Error{code: :profile_resolution_failed}} =
             ProfileResolver.resolve(request, fn _id, _opts -> raise "resolver failed" end)

    assert {:error, %Error{code: :malformed_profile_registration}} =
             ProfileResolver.resolve(request, fn _id, _opts -> {:ok, %{raw: true}} end)
  end

  test "unknown declared capability fails before an adapter is available" do
    registration = registration()
    request = PolicyRequest.new!(profile_id: "restricted", capability_ids: ["shell.unrestricted"])

    assert {:error, %Error{code: :insufficient_adapter_capability, details: details}} =
             ProfileResolver.resolve(request, fn _id, _opts -> {:ok, registration} end)

    assert details.dimension == :capability_ids
  end

  test "wrong identity and malformed profile fail before manager use" do
    wrong_request = PolicyRequest.new!(profile_id: "other")

    assert {:error, %Error{code: :profile_identity_mismatch}} =
             ProfileResolver.resolve(wrong_request, fn _id, _opts -> {:ok, registration()} end)

    malformed = %Registration{registration() | profile: %{profile_id: "restricted"}}
    request = PolicyRequest.new!(profile_id: "restricted")

    assert {:error, %Error{code: :malformed_profile_registration}} =
             ProfileResolver.resolve(request, fn _id, _opts -> {:ok, malformed} end)
  end

  defp registration(opts \\ []) do
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

    Registration.new!(
      profile: profile,
      adapter: FakeAdapter,
      capabilities: capabilities,
      enabled: Keyword.get(opts, :enabled, true)
    )
  end
end
