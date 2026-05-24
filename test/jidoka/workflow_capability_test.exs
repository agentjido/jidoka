defmodule JidokaTest.WorkflowCapabilityTest do
  use JidokaTest.Support.Case, async: false

  alias JidokaTest.WorkflowCapability.{
    ContextAgent,
    FailingAgent,
    MathAgent,
    MathWorkflow
  }

  test "compiled agents expose workflows as generated tool modules" do
    assert MathAgent.workflow_names() == ["run_math"]
    assert [%Jidoka.Workflow.Capability{name: "run_math", workflow: MathWorkflow}] = MathAgent.workflows()
    assert "run_math" in MathAgent.tool_names()

    tool = workflow_tool(MathAgent, "run_math")

    assert tool.schema() == MathWorkflow.input_schema()

    assert {:ok, %{output: %{value: 12}, workflow: metadata}} =
             tool.run(%{value: 5}, %{})

    assert metadata.name == "run_math"
    assert metadata.outcome == :ok
    assert metadata.input_keys == ["value"]
  end

  test "workflow capabilities forward selected public context" do
    tool = workflow_tool(ContextAgent, "context_echo")

    assert {:ok, %{output: "schemas:done"}} =
             tool.run(%{topic: "schemas"}, %{suffix: "done", secret: "hidden"})
  end

  test "workflow capability returns Jidoka validation errors for missing context refs" do
    tool = workflow_tool(ContextAgent, "context_echo")

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             tool.run(%{topic: "schemas"}, %{})

    assert error.message =~ "Missing workflow context key `suffix`"
    assert Jidoka.format_error(error) =~ "Missing workflow context key `suffix`"
  end

  test "workflow capability returns Jidoka validation errors for invalid input" do
    tool = workflow_tool(MathAgent, "run_math")

    assert {:error, %Jidoka.Error.ValidationError{} = error} =
             tool.run(%{value: "bad"}, %{})

    assert error.message =~ "Invalid workflow input"
  end

  test "workflow capability returns Jidoka execution errors for step failures" do
    tool = workflow_tool(FailingAgent, "fail_workflow")

    assert {:error, %Jidoka.Error.ExecutionError{} = error} =
             tool.run(%{reason: "boom"}, %{})

    assert error.message =~ "Workflow workflow_capability_failure step fail failed"
    assert error.details.step == :fail
  end

  test "workflow capability records request metadata when request context is present" do
    tool = workflow_tool(MathAgent, "run_math")
    request_id = "workflow-capability-#{System.unique_integer([:positive])}"

    assert {:ok, %{output: %{value: 12}}} =
             tool.run(%{value: 5}, %{
               Jidoka.Subagent.server_key() => self(),
               Jidoka.Subagent.request_id_key() => request_id
             })

    assert [%{name: "run_math", outcome: :ok, output_preview: preview}] =
             Jidoka.Workflow.Capability.request_calls(self(), request_id)

    assert preview =~ "value"
  end

  test "workflow metadata is retained from delegated ReAct worker events" do
    runtime = MathAgent.runtime_module()
    agent = new_runtime_agent(runtime)
    request_id = "workflow-worker-#{System.unique_integer([:positive])}"

    assert {:ok, agent, {:ai_react_start, params}} =
             runtime.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "run math",
                  request_id: request_id,
                  tool_context: %{tenant: "worker-event"}
                }}
             )

    tool = workflow_tool(MathAgent, "run_math")

    assert {:ok, %{output: %{value: 12}}} =
             tool.run(%{value: 5}, params.tool_context)

    assert {:ok, updated_agent, []} =
             runtime.on_after_cmd(
               agent,
               {:ai_react_worker_event, %{event: %{request_id: request_id, kind: :tool_completed}}},
               []
             )

    assert [%{name: "run_math", outcome: :ok, output_preview: preview}] =
             get_in(updated_agent.state, [
               :requests,
               request_id,
               :meta,
               :jidoka_workflows,
               :calls
             ])

    assert preview =~ "value"

    assert {:ok, %{workflows: [%{name: "run_math", outcome: :ok}]}} =
             Jidoka.Debug.request_summary(updated_agent, request_id)
  end

  test "workflow capability names conflict with other tool-like capabilities" do
    assert_raise Spark.Error.DslError, ~r/duplicate tool names.*workflow_capability_math/s, fn ->
      compile_agent("""
      defmodule JidokaTest.WorkflowCapability.DuplicateWorkflowToolAgent do
        use Jidoka.Agent

        agent :duplicate_workflow_tool_agent do
          instructions "This should fail."
        end

        tools do
          action JidokaTest.WorkflowCapability.DuplicateNameTool
        end

        capabilities do
          workflow JidokaTest.WorkflowCapability.MathWorkflow
        end
      end
      """)
    end
  end

  test "Jidoka.run/3 is not part of the beta public API" do
    assert Jidoka.format_error("beta") == "beta"
    refute function_exported?(Jidoka, :run, 3)
  end

  defp compile_agent(source), do: Code.compile_string(source)

  defp workflow_tool(agent_module, name) do
    Enum.find(agent_module.tools(), fn tool_module ->
      Code.ensure_loaded?(tool_module) and function_exported?(tool_module, :name, 0) and tool_module.name() == name
    end)
  end
end
