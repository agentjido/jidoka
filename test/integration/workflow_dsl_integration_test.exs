defmodule Jidoka.WorkflowDslIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule WorkflowFns do
    @moduledoc false

    def review_policy(%{order_id: order_id, amount: amount}, context) do
      tenant = Map.fetch!(context, :tenant)

      {:ok,
       %{
         order_id: order_id,
         amount: amount,
         tenant: tenant,
         summary: "Approve #{order_id} for #{tenant} up to #{amount}."
       }}
    end
  end

  defmodule RefundReviewWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:refund_review_workflow)
      description "Reviews refund policy using request input and tenant context."

      input Zoi.object(%{
              order_id: Zoi.string(),
              amount: Zoi.float()
            })
    end

    steps do
      function :review_policy, {WorkflowFns, :review_policy, 2},
        input: %{
          order_id: input("order_id"),
          amount: input(:amount)
        }
    end

    output %{
      order_id: from(:review_policy, :order_id),
      tenant: from(:review_policy, "tenant"),
      summary: from(:review_policy, :summary)
    }
  end

  defmodule RefundAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :workflow_refund_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the refund review workflow before answering refund questions."
    end

    tools do
      workflow RefundReviewWorkflow,
        as: :review_refund,
        forward_context: {:only, [:tenant]},
        result: :structured
    end
  end

  test "DSL workflow runs as an agent tool with structured output and forwarded context" do
    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "review_refund",
             arguments: %{"order_id" => "A1001", "amount" => 42.5}
           }}

        1 ->
          assert journal.results |> Map.values() |> Enum.any?(&(&1.kind == :operation))

          {:ok, %{type: :final, content: "Refund review approved for A1001."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Can we refund order A1001 for 42.50?",
        context: %{tenant: "acme", secret: "not forwarded"}
      )

    assert {:ok, %Turn.Result{content: "Refund review approved for A1001."} = result} =
             RefundAgent.run_turn(request,
               llm: llm,
               operation_context: %{parent_context: request.context}
             )

    assert [
             %Effect.OperationResult{
               operation: "review_refund",
               output: %{
                 workflow: "refund_review_workflow",
                 output: %{tenant: "acme"}
               }
             }
           ] = result.agent_state.operation_results
  end
end
