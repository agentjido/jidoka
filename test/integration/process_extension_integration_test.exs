defmodule Jidoka.ProcessExtensionIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Context
  alias Jidoka.Effect
  alias Jidoka.Extension.{Host, ProcessHost, Registration, Request}
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Runtime.{Capabilities, EffectInterpreter}
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.TestSupport.ProcessExtensionTransport
  alias Jidoka.Turn

  @hash "sha256:" <> String.duplicate("9", 64)

  test "process slots use the built-in host and host policy blocks frames before the child" do
    owner = self()
    {:ok, session} = Session.start(spec(), session_id: "process-host-session")
    {:ok, session} = Session.put_extension_state(session, %{"acme.process" => %{"count" => 1}})
    request = Request.new!(id: "acme.process")

    registry = %{
      "acme.process" => %{
        registration: registration(),
        factory: ProcessHost.factory(descriptor(owner), mode: :automation)
      }
    }

    assert {:ok, host} = Host.open(session, [request], registry, :automation)
    assert_receive {:protocol_frame, "state.restore", _message}
    assert {:ok, compiled} = host |> Host.operation_sources() |> Source.compile()

    policy = fn _request, %Context{} ->
      {:ok, Decision.new!(outcome: :deny, rule_id: "host.deny", reason: :not_allowed)}
    end

    capabilities =
      Capabilities.new!(
        llm: fn _, _, _ -> {:error, :unused} end,
        operations: compiled.capability,
        policy: policy
      )

    intent = Effect.Intent.new(:operation, %{name: "fixture_tool", arguments: %{}})

    assert {:error, %Jidoka.Error.ExecutionError{}} =
             EffectInterpreter.interpret_pending(turn_state(intent), capabilities)

    refute_receive {:protocol_frame, "tool.call", _message}

    assert {:ok, checkpointed} = Host.checkpoint(host, session)
    assert Session.extension_state(checkpointed) == %{"acme.process" => %{"count" => 2}}
    assert {:ok, %{"acme.process" => %{"answer" => 42}}} = Host.results(host)
    assert {:ok, %{"acme.process" => %{"panel" => "fixture"}}} = Host.ui_data(host)
    Host.close(host)
  end

  defp descriptor(owner) do
    %{
      transport: ProcessExtensionTransport,
      owner: owner,
      evidence: %{"status" => "enforced", "isolation" => "container"},
      extension_id: "acme.process",
      identity_hash: @hash,
      permissions: permissions(),
      capabilities: capabilities()
    }
  end

  defp registration do
    Registration.new!(%{
      identity: %{
        id: "acme.process",
        source_type: :process,
        source_ref: "registry:acme-process",
        release: "1.0.0",
        content_hash: @hash,
        trust: :trusted
      },
      permissions: permissions(),
      capabilities: capabilities(),
      modes: [:automation]
    })
  end

  defp permissions, do: ~w(context policy_advice providers results state tools ui_data)

  defp capabilities,
    do:
      ~w(protocol.command protocol.context protocol.lifecycle protocol.policy protocol.provider protocol.result protocol.state protocol.tool protocol.ui_data)

  defp spec do
    Agent.Spec.new!(
      id: "process_extension_agent",
      instructions: "Test process extensions.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp turn_state(intent) do
    request = Turn.Request.new!(input: "Run", request_id: "request-1")
    spec = spec()

    Turn.State.new!(spec: spec, plan: Turn.Plan.new!(spec), request: request, agent_state: request.agent_state)
    |> Turn.State.set_pending_effects([intent])
  end
end
