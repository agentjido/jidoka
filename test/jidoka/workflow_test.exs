defmodule JidokaTest.WorkflowTest do
  use JidokaTest.Support.Case, async: false

  @moduletag :capture_log

  alias JidokaTest.Workflow.{
    AgentWorkflow,
    EchoAgent,
    FailingWorkflow,
    FunctionWorkflow,
    ImportedAgentWorkflow,
    OrderedWorkflow,
    ToolOnlyWorkflow
  }

  test "runs an action-only workflow through the public module API" do
    assert {:ok, %{value: 12}} = ToolOnlyWorkflow.run(%{value: 5})
  end

  test "runs an action-only workflow through the top-level API" do
    assert {:ok, %{value: 12}} = Jidoka.Workflow.run(ToolOnlyWorkflow, %{value: 5})
  end

  test "normalizes keyword input through workflow schemas" do
    assert {:ok, %{value: 12}} = ToolOnlyWorkflow.run(value: 5)
  end

  test "runs a function workflow with runtime context refs" do
    assert {:ok, "schemas:done"} =
             FunctionWorkflow.run(%{topic: "schemas"}, context: %{suffix: "done"})
  end

  test "resolves string-key context refs" do
    assert {:ok, "schemas:done"} =
             FunctionWorkflow.run(%{topic: "schemas"}, context: %{"suffix" => "done"})
  end

  test "runs dependent workflow steps in order without model calls" do
    assert {:ok, %{value: 7}} =
             OrderedWorkflow.run(%{value: 5}, context: %{notify_pid: self()})

    assert_receive {:workflow_step, :first, 5}
    assert_receive {:workflow_step, :second, 6}
    refute_receive {:workflow_step, _label, _value}
  end

  test "returns a validation error for missing context refs" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             FunctionWorkflow.run(%{topic: "schemas"})

    assert error.message =~ "Missing workflow context key `suffix`"
  end

  test "runs a Jidoka-compatible agent workflow without live LLM calls" do
    assert {:ok, "echo:draft workflows:topic=workflows"} =
             AgentWorkflow.run(%{topic: "workflows"})
  end

  test "runs an imported-agent workflow using runtime agents" do
    assert {:ok, "echo:review draft:topic=reviews"} =
             ImportedAgentWorkflow.run(%{topic: "reviews"}, agents: %{reviewer: EchoAgent})
  end

  test "returns a validation error when an imported-agent ref is not supplied" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             ImportedAgentWorkflow.run(%{topic: "reviews"})

    assert error.message =~ "Missing imported workflow agent `reviewer`"
  end

  test "parses input through the declared Zoi schema" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             ToolOnlyWorkflow.run(%{value: "not-an-integer"})

    assert error.message =~ "Invalid workflow input"
  end

  test "requires input to be a map or keyword list" do
    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             ToolOnlyWorkflow.run("bad")

    assert error.message =~ "pass input as a map or keyword list"
  end

  test "returns debug data when requested" do
    assert {:ok, debug} = ToolOnlyWorkflow.run(%{value: 5}, return: :debug)

    assert debug.workflow_id == "tool_only_workflow"
    assert debug.status == :success
    assert debug.output == %{value: 12}
    assert debug.steps.add == %{value: 6}
    assert debug.steps.double == %{value: 12}
    assert %{nodes: nodes, edges: edges} = debug.graph
    assert Enum.any?(nodes, &(&1.name == :add))
    assert Enum.any?(edges, &(&1.label in [:connects_to, :flow]))
  end

  test "surfaces failing step errors as Jidoka execution errors" do
    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             FailingWorkflow.run(%{reason: "boom"})

    assert error.message =~ "Workflow failing_workflow step fail failed"
    assert error.details.step == :fail
    assert error.details.reason == "boom"
  end

  test "inspects a workflow definition" do
    assert {:ok, inspection} = Jidoka.inspect_workflow(ToolOnlyWorkflow)

    assert inspection.kind == :workflow_definition
    assert inspection.id == "tool_only_workflow"
    assert Enum.map(inspection.steps, & &1.name) == [:add, :double]
    assert Enum.map(inspection.steps, & &1.kind) == [:action, :action]
    assert inspection.dependencies.double == [:add]
    refute Map.has_key?(inspection, :graph)
    refute Map.has_key?(inspection, :node_map)
    refute Map.has_key?(inspection, :execution_summary)
  end
end
