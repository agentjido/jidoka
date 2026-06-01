defmodule Jidoka.WorkflowTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Turn

  defmodule MathWorkflow do
    @moduledoc false

    use Jidoka.Workflow,
      id: :math_workflow,
      description: "Adds one and doubles the value.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "integer"}},
        "required" => ["value"]
      }

    @impl true
    def run(input, context) do
      value = Map.get(input, :value, Map.get(input, "value"))
      suffix = Map.get(context, :suffix, Map.get(context, "suffix", "ok"))

      {:ok, %{value: (value + 1) * 2, suffix: suffix}}
    end
  end

  defmodule WorkflowAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :workflow_agent do
      model %{provider: :test, id: "model"}
      instructions "Use run_math for deterministic arithmetic."
    end

    tools do
      workflow MathWorkflow,
        as: :run_math,
        forward_context: {:only, [:suffix]},
        result: :structured
    end
  end

  test "workflows compile into operation specs and metadata" do
    assert [
             %Operation{
               name: "run_math",
               metadata: %{
                 "source" => "workflow",
                 "kind" => "workflow",
                 "workflow" => "math_workflow",
                 "parameters_schema" => %{"required" => ["value"]}
               }
             } = operation
           ] = WorkflowAgent.spec().operations

    assert Operation.kind(operation) == :workflow

    assert [
             %{
               "source" => "workflow",
               "name" => "run_math",
               "workflow" => "math_workflow"
             }
           ] = WorkflowAgent.spec().metadata["tool_sources"]
  end

  test "workflow operations run deterministic workflow modules" do
    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "run_math", arguments: %{"value" => 5}}}
        1 -> {:ok, %{type: :final, content: "The deterministic result is 12."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Run deterministic math.",
        context: %{suffix: "done", secret: "hidden"}
      )

    assert {:ok, %Turn.Result{} = result} =
             WorkflowAgent.run_turn(request,
               llm: llm,
               operation_context: %{parent_context: request.context}
             )

    assert [
             %Effect.OperationResult{
               operation: "run_math",
               output: %{
                 workflow: "math_workflow",
                 operation: "run_math",
                 output: %{value: 12, suffix: "done"}
               }
             }
           ] = result.agent_state.operation_results
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end
end
