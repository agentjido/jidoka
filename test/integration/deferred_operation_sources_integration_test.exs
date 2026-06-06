defmodule Jidoka.DeferredOperationSourcesIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Local
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule SourceAuditControl do
    @moduledoc false

    use Jidoka.Control, name: "deferred_source_audit"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :source_audit,
        operation.kind,
        operation.source,
        operation.operation,
        operation.operation_metadata
      })

      :cont
    end
  end

  defmodule HandoffReviewControl do
    @moduledoc false

    use Jidoka.Control, name: "handoff_review"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :handoff_review_requested,
        operation.kind,
        operation.source,
        operation.operation
      })

      {:interrupt, :handoff_requires_review}
    end
  end

  test "skill-like sources execute as ordinary tool operations with source controls" do
    test_pid = self()

    source =
      Local.new!(
        operations: [
          %{
            name: "summarize_policy",
            description: "Runs a policy summarization skill.",
            kind: :tool,
            metadata: %{"source" => "skill", "skill" => "policy_summary"},
            handler: fn %{"topic" => topic}, _ctx ->
              send(test_pid, {:skill_called, topic})
              %{summary: "Policy summary for #{topic}."}
            end
          }
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} = Source.compile(source)

    spec =
      Agent.Spec.new!(
        id: "skill_source_agent",
        instructions: "Use summarize_policy for policy summary requests.",
        model: %{provider: :test, id: "model"},
        operations: operations,
        controls: %{
          operations: [
            %{
              control: SourceAuditControl,
              match: %{source: "skill", metadata: %{skill: "policy_summary"}}
            }
          ]
        }
      )

    request =
      Turn.Request.new!(
        input: "Summarize the refunds policy.",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %Turn.Result{content: "Refund policy summarized."} = result} =
             Jidoka.turn(spec, request,
               llm: llm("summarize_policy", %{"topic" => "refunds"}, "Refund policy summarized."),
               operations: capability
             )

    assert_receive {:source_audit, :tool, "skill", "summarize_policy",
                    %{"source" => "skill", "skill" => "policy_summary"}}

    assert_receive {:skill_called, "refunds"}

    assert [%Effect.OperationResult{operation: "summarize_policy"}] =
             result.agent_state.operation_results
  end

  test "workflow-like sources execute through the same operation source path" do
    test_pid = self()

    source =
      Local.new!(
        operations: [
          %{
            name: "run_triage_workflow",
            description: "Runs the known triage workflow.",
            kind: :workflow,
            metadata: %{"source" => "workflow", "workflow" => "triage"},
            handler: fn %{"ticket_id" => ticket_id}, _ctx ->
              send(test_pid, {:workflow_called, ticket_id})
              %{ticket_id: ticket_id, route: "billing"}
            end
          }
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} = Source.compile(source)

    spec =
      Agent.Spec.new!(
        id: "workflow_source_agent",
        instructions: "Use run_triage_workflow for ticket triage.",
        model: %{provider: :test, id: "model"},
        operations: operations,
        controls: %{
          operations: [
            %{
              control: SourceAuditControl,
              match: %{kind: :workflow, source: "workflow"}
            }
          ]
        }
      )

    request =
      Turn.Request.new!(
        input: "Triage ticket T-200.",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %Turn.Result{content: "Ticket T-200 routes to billing."} = result} =
             Jidoka.turn(spec, request,
               llm:
                 llm(
                   "run_triage_workflow",
                   %{"ticket_id" => "T-200"},
                   "Ticket T-200 routes to billing."
                 ),
               operations: capability
             )

    assert_receive {:source_audit, :workflow, "workflow", "run_triage_workflow",
                    %{"source" => "workflow", "workflow" => "triage"}}

    assert_receive {:workflow_called, "T-200"}

    assert [%Effect.OperationResult{operation: "run_triage_workflow"}] =
             result.agent_state.operation_results
  end

  test "handoff-like sources can be reviewed, hibernated, approved, and resumed" do
    test_pid = self()

    source =
      Local.new!(
        operations: [
          %{
            name: "handoff_to_billing",
            description: "Transfers ownership to the billing agent.",
            kind: :handoff,
            idempotency: :unsafe_once,
            metadata: %{"source" => "handoff", "target" => "billing_agent"},
            handler: fn %{"case_id" => case_id}, _ctx ->
              send(test_pid, {:handoff_called, case_id})
              {:ok, %{case_id: case_id, target: "billing_agent", status: "accepted"}}
            end
          }
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} = Source.compile(source)

    spec =
      Agent.Spec.new!(
        id: "handoff_source_agent",
        instructions: "Use handoff_to_billing when a billing specialist should own the case.",
        model: %{provider: :test, id: "model"},
        operations: operations,
        controls: %{
          operations: [
            %{
              control: HandoffReviewControl,
              match: %{kind: :handoff, source: "handoff", metadata: %{target: "billing_agent"}}
            }
          ]
        }
      )

    request =
      Turn.Request.new!(
        input: "Move case C-300 to billing.",
        context: %{test_pid: test_pid}
      )

    assert {:hibernate, %AgentSnapshot{} = snapshot} =
             Jidoka.turn(spec, request,
               llm:
                 llm(
                   "handoff_to_billing",
                   %{"case_id" => "C-300"},
                   "Billing agent accepted case C-300."
                 ),
               operations: capability,
               clock: clock(10_000)
             )

    assert snapshot.cursor.phase == :review
    assert snapshot.turn_state.pending_interrupt.operation == "handoff_to_billing"
    assert snapshot.turn_state.pending_interrupt.operation_kind == :handoff
    assert snapshot.metadata["pending_review"].operation == "handoff_to_billing"

    assert_receive {:handoff_review_requested, :handoff, "handoff", "handoff_to_billing"}
    refute_received {:handoff_called, _case_id}

    approval =
      Review.Response.approve(snapshot.turn_state.pending_interrupt, responded_at_ms: 10_001)

    assert {:ok, %Turn.Result{content: "Billing agent accepted case C-300."} = result} =
             Jidoka.resume(snapshot,
               approval: approval,
               llm:
                 llm(
                   "handoff_to_billing",
                   %{"case_id" => "C-300"},
                   "Billing agent accepted case C-300."
                 ),
               operations: capability,
               clock: clock(10_001)
             )

    assert_receive {:handoff_called, "C-300"}

    assert [%Effect.OperationResult{operation: "handoff_to_billing"}] =
             result.agent_state.operation_results
  end

  test "deferred source families are exposed as tools DSL entities" do
    entity_names =
      Jidoka.Agent.Dsl.Sections.Tools.section().entities
      |> Enum.map(& &1.name)

    assert :action in entity_names
    assert :ash_resource in entity_names
    assert :browser in entity_names
    assert :skill in entity_names
    assert :workflow in entity_names
    assert :handoff in entity_names
  end

  defp llm(operation, arguments, final_content) do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: operation, arguments: arguments}}
        1 -> {:ok, %{type: :final, content: final_content}}
      end
    end
  end

  defp clock(now_ms), do: fn -> now_ms end
end
