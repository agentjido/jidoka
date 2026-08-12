defmodule Jidoka.ExtensionHostIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Extension.OperationSource
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Turn

  test "host policy denial stops an extension tool before its handler" do
    operation = Operation.new!(name: "extension_delete", idempotency: :pure)

    source = %OperationSource{
      namespace: "acme.tools",
      operations: [operation],
      handlers: %{"extension_delete" => fn _, _ -> flunk("denied tool handler ran") end}
    }

    assert {:ok, compiled} = Source.compile(source)

    policy = fn _request, %Context{} ->
      {:ok, Decision.new!(outcome: :deny, rule_id: "host.deny", reason: :not_allowed)}
    end

    capabilities =
      Capabilities.new!(
        llm: fn _, _, _ -> {:error, :unused} end,
        operations: compiled.capability,
        policy: policy
      )

    intent = Effect.Intent.new(:operation, %{name: "extension_delete", arguments: %{}})

    assert {:error, %Jidoka.Error.ExecutionError{details: details}} =
             EffectInterpreter.interpret_pending(turn_state(intent), capabilities)

    assert inspect(details) =~ "policy_denied"
  end

  defp turn_state(intent) do
    spec =
      Agent.Spec.new!(
        id: "extension_policy_agent",
        instructions: "Test policy.",
        model: %{provider: :test, id: "model"}
      )

    request = Turn.Request.new!(input: "Run", request_id: "request-1")

    Turn.State.new!(
      spec: spec,
      plan: Turn.Plan.new!(spec),
      request: request,
      agent_state: request.agent_state
    )
    |> Turn.State.set_pending_effects([intent])
  end
end
