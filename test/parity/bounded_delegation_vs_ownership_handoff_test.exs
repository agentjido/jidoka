defmodule Jidoka.Parity.BoundedDelegationVsOwnershipHandoffTest do
  use Jidoka.ParityCase, parity: :bounded_delegation_vs_ownership_handoff

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Handoff
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule SpecialistAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :ownership_specialist do
      model %{provider: :test, id: "model"}
      instructions "Complete the bounded task or own the transferred conversation."
    end
  end

  defmodule AllowHandoff do
    @moduledoc false

    use Jidoka.Control, name: "allow_handoff"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :handoff_allowed,
        operation.kind,
        operation.source,
        operation.operation
      })

      :cont
    end
  end

  defmodule RouterAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :delegation_handoff_router do
      model %{provider: :test, id: "model"}
      instructions "Delegate bounded work or transfer future conversation ownership."
    end

    controls do
      operation AllowHandoff, when: [kind: :handoff, name: "transfer_to_specialist"]
    end

    tools do
      subagent SpecialistAgent,
        as: :bounded_specialist,
        description: "Returns bounded evidence to the router.",
        forward_context: {:only, [:tenant]},
        result: :structured

      handoff SpecialistAgent,
        as: :transfer_to_specialist,
        description: "Transfers future turns to the specialist.",
        forward_context: {:only, [:tenant, :session_id]}
    end
  end

  test "bounded delegation returns while an allowed handoff records an app-dispatched owner" do
    test_pid = self()
    conversation_id = "parity-handoff-#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn -> Jidoka.reset_handoff(conversation_id) end)

    operations = Map.new(RouterAgent.spec().operations, &{&1.name, &1})

    assert %Operation{idempotency: :idempotent} = bounded_operation = operations["bounded_specialist"]
    assert Operation.kind(bounded_operation) == :subagent

    assert %Operation{idempotency: :unsafe_once} = handoff_operation = operations["transfer_to_specialist"]
    assert Operation.kind(handoff_operation) == :handoff

    delegation_llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _context ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"delegation_handoff_router", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "bounded_specialist",
             arguments: %{"task" => "Return bounded account evidence."}
           }}

        {"ownership_specialist", 0} ->
          send(test_pid, {:bounded_child_context, payload.prompt.context})
          {:ok, %{type: :final, content: "The bounded evidence is complete."}}

        {"delegation_handoff_router", 1} ->
          {:ok, %{type: :final, content: "The router synthesized the child result."}}

        unexpected ->
          raise "unexpected delegation model call: #{inspect(unexpected)}"
      end
    end

    delegation_request =
      Turn.Request.new!(
        input: "Check this account without transferring the conversation.",
        context: %{
          tenant: "acme",
          secret: "router-only-secret",
          session_id: conversation_id
        }
      )

    assert {:ok, %Turn.Result{} = delegated_result} =
             RouterAgent.run_turn(delegation_request,
               llm: delegation_llm,
               operation_context: %{subagent_llm: delegation_llm}
             )

    assert delegated_result.content == "The router synthesized the child result."

    assert [
             %Effect.OperationResult{
               operation: "bounded_specialist",
               output: %{
                 subagent: "bounded_specialist",
                 content: "The bounded evidence is complete."
               }
             }
           ] = delegated_result.agent_state.operation_results

    assert_receive {:bounded_child_context, %{tenant: "acme"} = child_context}

    assert map_size(child_context) == 1

    refute Map.has_key?(child_context, :secret)
    refute Map.has_key?(child_context, "secret")
    assert Jidoka.handoff(conversation_id) == nil

    handoff_llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _context ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"delegation_handoff_router", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "transfer_to_specialist",
             arguments: %{
               "message" => "Continue with specialist account support.",
               "summary" => "The account needs specialist follow-up.",
               "reason" => "specialist_ownership_required"
             }
           }}

        {"delegation_handoff_router", 1} ->
          {:ok, %{type: :final, content: "The handoff was recorded."}}

        unexpected ->
          raise "unexpected handoff model call: #{inspect(unexpected)}"
      end
    end

    handoff_request =
      Turn.Request.new!(
        input: "Transfer this conversation to the specialist.",
        context: %{
          test_pid: test_pid,
          tenant: "acme",
          secret: "router-only-secret",
          session_id: conversation_id
        }
      )

    {handoff_pid, handoff_ref} =
      spawn_monitor(fn ->
        result = RouterAgent.run_turn(handoff_request, llm: handoff_llm)
        send(test_pid, {:handoff_turn_result, self(), result})
      end)

    assert_receive {:handoff_turn_result, ^handoff_pid, {:ok, %Turn.Result{} = handoff_result}}
    assert_receive {:DOWN, ^handoff_ref, :process, ^handoff_pid, :normal}

    assert_receive {:handoff_allowed, :handoff, "handoff", "transfer_to_specialist"}

    assert [
             %Effect.OperationResult{
               operation: "transfer_to_specialist",
               output: %{
                 handoff: %{
                   name: "transfer_to_specialist",
                   conversation_id: ^conversation_id,
                   message: "Continue with specialist account support.",
                   summary: "The account needs specialist follow-up.",
                   context: handoff_context
                 },
                 owner: %{
                   conversation_id: ^conversation_id,
                   agent: target_agent,
                   agent_id: owner_agent_id,
                   name: "transfer_to_specialist"
                 }
               }
             }
           ] = handoff_result.agent_state.operation_results

    assert handoff_context == %{tenant: "acme", session_id: conversation_id}
    assert owner_agent_id == "#{conversation_id}:transfer_to_specialist"
    assert target_agent =~ "SpecialistAgent"

    assert %{
             agent: SpecialistAgent,
             agent_id: ^owner_agent_id,
             handoff: %Handoff{
               conversation_id: ^conversation_id,
               name: "transfer_to_specialist",
               context: %{tenant: "acme", session_id: ^conversation_id}
             }
           } = owner = Jidoka.handoff(conversation_id)

    refute Map.has_key?(owner.handoff.context, :secret)
    refute Map.has_key?(owner.handoff.context, "secret")

    direct_router_llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{}, _context ->
      send(test_pid, {:direct_agent_called, payload.agent_id})
      {:ok, %{type: :final, content: "The router answered because it was invoked directly."}}
    end

    assert {:ok, %Turn.Result{content: "The router answered because it was invoked directly."}} =
             RouterAgent.run_turn(
               Turn.Request.new!(
                 input: "Invoke the router directly after handoff.",
                 context: %{session_id: conversation_id}
               ),
               llm: direct_router_llm
             )

    assert_receive {:direct_agent_called, "delegation_handoff_router"}
    assert %{agent_id: ^owner_agent_id} = Jidoka.handoff(conversation_id)

    fresh_input = "Continue this conversation with fresh specialist follow-up."

    app_dispatch_llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{}, _context ->
      send(test_pid, {:app_dispatched_agent, payload.agent_id, payload.prompt.messages})
      {:ok, %{type: :final, content: "The specialist handled the app-dispatched turn."}}
    end

    assert %{agent: owner_agent, handoff: app_handoff} =
             Jidoka.handoff(conversation_id)

    fresh_follow_up =
      Turn.Request.new!(
        input: fresh_input,
        context: app_handoff.context
      )

    assert {:ok, %Turn.Result{content: "The specialist handled the app-dispatched turn."}} =
             owner_agent.run_turn(fresh_follow_up, llm: app_dispatch_llm)

    assert_receive {:app_dispatched_agent, "ownership_specialist", specialist_messages}

    assert Enum.any?(
             specialist_messages,
             &match?(%{role: :user, content: ^fresh_input}, &1)
           )

    assert :ok = Jidoka.reset_handoff(conversation_id)
    assert Jidoka.handoff(conversation_id) == nil
  end
end
