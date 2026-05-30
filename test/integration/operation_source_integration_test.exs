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

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
