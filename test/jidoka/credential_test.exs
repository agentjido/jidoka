defmodule JidokaTest.CredentialTest do
  use JidokaTest.Support.Case, async: true

  alias Jidoka.Credential

  test "normalizes credential reference fields" do
    assert {:ok, %Credential{} = credential} =
             Credential.new(
               provider: :github,
               account: " acct_123 ",
               actor: "user_123",
               tenant: :acme,
               scopes: [:repo, "issues:write", "repo"],
               lease_id: "lease_123",
               expires_at: "2026-05-24T12:00:00Z",
               risk: "HIGH",
               confirmation_required: "true",
               audit_metadata: [request_id: "req_123"]
             )

    assert credential.provider == "github"
    assert credential.account == "acct_123"
    assert credential.actor == "user_123"
    assert credential.tenant == "acme"
    assert credential.scopes == ["repo", "issues:write"]
    assert credential.lease_id == "lease_123"
    assert credential.expires_at == ~U[2026-05-24 12:00:00Z]
    assert credential.risk == :high
    assert credential.confirmation_required
    assert credential.audit_metadata == %{request_id: "req_123"}
  end

  test "requires a provider" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} = Credential.new(account: "acct_123")

    assert error.field == :provider
    assert error.details.reason == :required
  end

  test "rejects invalid risk without interning arbitrary atoms" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Credential.new(provider: "github", risk: "tenant-supplied-risk")

    assert error.field == :risk
    assert error.details.reason == :invalid_risk
  end

  test "rejects invalid scopes and audit metadata" do
    assert {:error, %Jidoka.Error.ValidationError{} = scope_error} =
             Credential.new(provider: "github", scopes: ["repo", ""])

    assert scope_error.field == :scopes
    assert scope_error.details.reason == :empty_scope

    assert {:error, %Jidoka.Error.ValidationError{} = metadata_error} =
             Credential.new(provider: "github", audit_metadata: [:not_a_pair])

    assert metadata_error.field == :audit_metadata
    assert metadata_error.details.reason == :expected_map
  end

  test "raises from new bang on invalid input" do
    assert_raise Jidoka.Error.ValidationError, fn ->
      Credential.new!(provider: "")
    end
  end
end
