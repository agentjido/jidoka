defmodule Jidoka.OperationSourceIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Local
  alias Jidoka.Turn

  defmodule SourceAuditControl do
    @moduledoc false

    use Jidoka.Control, name: "source_audit"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {:source_control, operation.kind, operation.operation})
      :cont
    end
  end

  defmodule SourceMatchControl do
    @moduledoc false

    use Jidoka.Control, name: "source_match"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :source_match_control,
        operation.source,
        operation.idempotency,
        operation.operation_metadata["risk"]
      })

      :cont
    end
  end

  test "non-action operation sources run through the same operation effect path" do
    test_pid = self()

    source =
      Local.new!(
        operations: [
          %{
            name: "lookup_ticket",
            description: "Looks up a ticket.",
            kind: :tool,
            handler: fn args -> %{ticket_id: args["ticket_id"], status: "open"} end
          }
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} = Source.compile(source)

    spec =
      Agent.Spec.new!(
        id: "operation_source_agent",
        instructions: "Use lookup_ticket when asked about a ticket.",
        model: %{provider: :test, id: "model"},
        operations: operations,
        controls:
          Controls.new!(
            operations: [
              %{control: SourceAuditControl, match: %{kind: :tool, name: "lookup_ticket"}}
            ]
          ),
        runtime_defaults: %{max_model_turns: 4}
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_ticket",
             arguments: %{"ticket_id" => "T-100"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Ticket T-100 is open."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Check ticket T-100",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %Turn.Result{content: "Ticket T-100 is open."} = result} =
             Jidoka.run_turn(spec, request, llm: llm, operations: capability)

    assert [%Effect.OperationResult{operation: "lookup_ticket"}] =
             result.agent_state.operation_results

    assert_receive {:source_control, :tool, "lookup_ticket"}
  end

  test "operation controls can match source idempotency and metadata at runtime" do
    test_pid = self()

    source =
      Local.new!(
        operations: [
          %{
            name: "charge_card",
            description: "Charges a card.",
            idempotency: :unsafe_once,
            kind: :tool,
            metadata: %{"source" => "payments", "risk" => "high"},
            handler: fn args -> %{charge_id: args["charge_id"], status: "approved"} end
          }
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} = Source.compile(source)

    spec =
      Agent.Spec.new!(
        id: "operation_source_policy_agent",
        instructions: "Use charge_card when asked to charge a card.",
        model: %{provider: :test, id: "model"},
        operations: operations,
        controls:
          Controls.new!(
            operations: [
              %{
                control: SourceMatchControl,
                match: %{
                  source: "payments",
                  idempotency: :unsafe_once,
                  metadata: %{risk: "high"}
                }
              }
            ]
          )
      )

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "charge_card",
             arguments: %{"charge_id" => "ch_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Charge ch_123 approved."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Charge ch_123",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %Turn.Result{content: "Charge ch_123 approved."}} =
             Jidoka.run_turn(spec, request, llm: llm, operations: capability)

    assert_receive {:source_match_control, "payments", :unsafe_once, "high"}
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
