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

  test "detects raw credential-looking keys while allowing credential references" do
    assert Credential.raw_secret_paths(%{
             credentials: [
               Credential.new!(provider: "github", lease_id: "lease_123"),
               %{api_key: "raw-secret"}
             ]
           }) == ["credentials.1.api_key"]

    assert :ok =
             Credential.reject_raw_secrets(%{
               credential: Credential.new!(provider: "github", lease_id: "lease_123")
             })
  end

  test "public chat context rejects raw secrets before provider prompts or tools" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Agent.prepare_chat_opts([context: %{tenant: "acme", api_key: "raw-secret"}], nil)

    assert error.field == :context
    assert error.details.reason == :raw_credential_value
    assert error.details.paths == ["api_key"]
    assert error.value == "[REDACTED]"
  end

  test "session context rejects raw secrets before runtime use" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             Jidoka.Session.new(agent: JidokaTest.ChatAgent, id: "credential-session", context: %{token: "raw"})

    assert error.field == :context
    assert error.details.paths == ["token"]
  end

  test "operation preflight rejects raw secrets in tool arguments" do
    runtime = JidokaTest.GuardrailedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Guardrails.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "call a tool", request_id: "req-credential-tool", tool_context: %{}}},
               %{input: [], output: [], tool: []}
             )

    callback = Map.fetch!(params.tool_context, :__tool_guardrail_callback__)

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             callback.(%{
               tool_name: "github_create_issue",
               tool_call_id: "tc-secret",
               arguments: %{title: "Hello", access_token: "raw-secret"},
               context: params.tool_context
             })

    assert error.field == :arguments
    assert error.details.reason == :raw_credential_value
    assert error.details.paths == ["access_token"]
  end

  test "operation controls can match credential reference metadata" do
    runtime = JidokaTest.GuardrailedAgent.runtime_module()
    agent = new_runtime_agent(runtime)

    credential =
      Credential.new!(
        provider: "github",
        account: "acct_123",
        tenant: "acme",
        scopes: ["repo", "issues:write"],
        risk: :high,
        confirmation_required: true
      )

    control = %Jidoka.Control.Operation{
      ref: JidokaTest.BlockOperationControl,
      match: %{
        credential: %{
          provider: "github",
          tenant: "acme",
          scope: "repo",
          risk: :high,
          confirmation_required: true
        }
      }
    }

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Guardrails.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "call a tool",
                  request_id: "req-credential-match",
                  tool_context: %{credential_ref: credential}
                }},
               %{input: [], output: [], tool: [control]}
             )

    callback = Map.fetch!(params.tool_context, :__tool_guardrail_callback__)

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             callback.(%{
               tool_name: "github_create_issue",
               tool_call_id: "tc-credential-match",
               arguments: %{title: "Hello"},
               context: params.tool_context
             })

    assert error.details.label == "block_operation"
    assert error.details.cause == :operation_blocked

    assert :ok =
             callback.(%{
               tool_name: "github_create_issue",
               tool_call_id: "tc-credential-skip",
               arguments: %{credential_ref: %{provider: "slack", scopes: ["chat:write"]}},
               context: %{}
             })
  end
end
