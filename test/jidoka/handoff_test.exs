defmodule Jidoka.HandoffTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Handoff
  alias Jidoka.Handoff.OwnerStore
  alias Jidoka.Handoff.OwnerStore.InMemory
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule BillingAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :billing_agent do
      model %{provider: :test, id: "model"}
      instructions "Own billing follow-up."
    end
  end

  defmodule AllowHandoff do
    @moduledoc false

    use Jidoka.Control, name: "allow_handoff"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :handoff_checked,
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

    agent :router_agent do
      model %{provider: :test, id: "model"}
      instructions "Use billing_specialist when billing should own the conversation."
    end

    controls do
      operation AllowHandoff, when: [kind: :handoff, name: "billing_specialist"]
    end

    tools do
      handoff BillingAgent,
        as: :billing_specialist,
        description: "Transfers future turns to billing.",
        forward_context: {:only, [:tenant, :session_id]},
        metadata: %{team: "billing"}
    end
  end

  setup do
    Jidoka.reset_handoff("conv-handoff-test")
    :ok
  end

  test "handoffs compile into unsafe operation specs and metadata" do
    assert [
             %Operation{
               name: "billing_specialist",
               idempotency: :unsafe_once,
               metadata: %{
                 "source" => "handoff",
                 "kind" => "handoff",
                 "agent" => agent,
                 "parameters_schema" => %{"required" => ["message"]}
               }
             } = operation
           ] = RouterAgent.spec().operations

    assert agent =~ "BillingAgent"
    assert Operation.kind(operation) == :handoff

    assert [
             %{
               "source" => "handoff",
               "name" => "billing_specialist",
               "agent" => source_agent
             }
           ] = RouterAgent.spec().metadata["tool_sources"]

    assert source_agent =~ "BillingAgent"
  end

  test "handoff data and owner store facades handle invalid boundaries" do
    assert Handoff.schema()

    assert {:error, _reason} =
             Handoff.new(%{
               from_agent: RouterAgent,
               to_agent: BillingAgent,
               to_agent_id: "billing_agent",
               name: "billing_specialist",
               message: ""
             })

    assert OwnerStore.owner(:not_a_conversation) == nil
    assert OwnerStore.put_owner(nil, :not_a_handoff) == :ok
    assert OwnerStore.reset(nil) == :ok
  end

  test "handoff operations record a conversation owner" do
    test_pid = self()

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "billing_specialist",
             arguments: %{
               "message" => "Please handle invoice INV-1.",
               "summary" => "Customer needs billing help.",
               "reason" => "billing_specialist_required"
             }
           }}

        1 ->
          {:ok, %{type: :final, content: "Billing now owns the conversation."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Move this to billing.",
        context: %{test_pid: test_pid, tenant: "acme", session_id: "conv-handoff-test"}
      )

    assert {:ok, %Turn.Result{} = result} =
             RouterAgent.run_turn(request, llm: llm)

    assert_receive {:handoff_checked, :handoff, "handoff", "billing_specialist"}

    assert [
             %Effect.OperationResult{
               operation: "billing_specialist",
               output: %{
                 handoff: %{
                   name: "billing_specialist",
                   conversation_id: "conv-handoff-test",
                   message: "Please handle invoice INV-1.",
                   summary: "Customer needs billing help.",
                   context: %{tenant: "acme", session_id: "conv-handoff-test"}
                 },
                 owner: %{agent_id: "conv-handoff-test:billing_specialist"}
               }
             }
           ] = result.agent_state.operation_results

    assert %{
             agent: BillingAgent,
             agent_id: "conv-handoff-test:billing_specialist",
             handoff: %Handoff{name: "billing_specialist"}
           } = Jidoka.handoff("conv-handoff-test")
  end

  test "default owner store survives the writer process" do
    conversation_id = "conv-handoff-writer-#{System.unique_integer([:positive, :monotonic])}"
    owner_agent_id = "#{conversation_id}:billing_specialist"
    owner_process = Process.whereis(InMemory)

    assert is_pid(owner_process)

    assert {InMemory, ^owner_process, :worker, [InMemory]} =
             Enum.find(Supervisor.which_children(Jidoka.Supervisor), fn
               {InMemory, _pid, :worker, [InMemory]} -> true
               _child -> false
             end)

    assert :ets.info(:jidoka_handoff_owners, :owner) == owner_process

    on_exit(fn -> Jidoka.reset_handoff(conversation_id) end)

    handoff =
      Handoff.new!(
        id: "handoff-writer-process",
        conversation_id: conversation_id,
        from_agent: RouterAgent,
        to_agent: BillingAgent,
        to_agent_id: owner_agent_id,
        name: "billing_specialist",
        message: "Continue with billing."
      )

    test_pid = self()

    {writer_pid, writer_ref} =
      spawn_monitor(fn ->
        :ok = OwnerStore.put_owner(conversation_id, handoff)
        send(test_pid, {:handoff_owner_written, self()})
      end)

    assert_receive {:handoff_owner_written, ^writer_pid}
    assert_receive {:DOWN, ^writer_ref, :process, ^writer_pid, :normal}

    assert %{
             agent: BillingAgent,
             agent_id: ^owner_agent_id,
             handoff: %Handoff{conversation_id: ^conversation_id}
           } = Jidoka.handoff(conversation_id)
  end
end
