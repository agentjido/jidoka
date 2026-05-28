defmodule JidokaTest.OperationSurfaceTest do
  use JidokaTest.Support.Case, async: false

  alias Jidoka.Web.Tools.SearchWeb

  alias JidokaTest.{
    AddNumbers,
    FakeMCPSync,
    MathPlugin,
    MCPAgent,
    MultiplyNumbers,
    PluginAgent,
    SkillAgent,
    ToolAgent,
    WebSearchAgent
  }

  alias JidokaTest.WorkflowCapability.{MathAgent, MathWorkflow}

  setup do
    previous_sync_module = Application.get_env(:jidoka, :mcp_sync_module)

    on_exit(fn ->
      if previous_sync_module do
        Application.put_env(:jidoka, :mcp_sync_module, previous_sync_module)
      else
        Application.delete_env(:jidoka, :mcp_sync_module)
      end
    end)

    :ok
  end

  test "operation sources expose action modules and provider-visible names consistently" do
    assert operation_surface(ToolAgent) == {[AddNumbers], ["add_numbers"]}
    assert operation_surface(PluginAgent) == {[MultiplyNumbers], ["multiply_numbers"]}
    assert operation_surface(SkillAgent) == {[MultiplyNumbers], ["multiply_numbers"]}
    assert operation_surface(WebSearchAgent) == {[SearchWeb], ["search_web"]}

    assert Enum.sort(AshResourceAgent.tool_names()) == ["create_user", "list_users"]
    assert length(AshResourceAgent.tools()) == 2

    assert MathAgent.workflow_names() == ["run_math"]
    assert "run_math" in MathAgent.tool_names()

    workflow_tool = find_tool(MathAgent, "run_math")
    assert workflow_tool in MathAgent.tools()
    refute MathWorkflow in MathAgent.tools()
    assert workflow_tool.schema() == MathWorkflow.input_schema()
    assert [%Jidoka.Workflow.Capability{workflow: MathWorkflow, name: "run_math"}] = MathAgent.workflows()
  end

  test "imported specs merge allowlisted actions and plugins into the same provider tool surface" do
    assert {:ok, agent} =
             Jidoka.import_agent(
               %{
                 "agent" => %{"id" => "operation_surface_import"},
                 "defaults" => %{"instructions" => "Use allowlisted operations."},
                 "capabilities" => %{"tools" => ["add_numbers"], "plugins" => ["math_plugin"]}
               },
               available_tools: [AddNumbers],
               available_plugins: [MathPlugin]
             )

    assert agent.tool_modules == [AddNumbers, MultiplyNumbers]
    assert Enum.map(agent.tool_modules, & &1.name()) == ["add_numbers", "multiply_numbers"]
  end

  test "MCP entries use the same operation sync boundary at runtime" do
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    assert MCPAgent.mcp_tools() == [%{endpoint: :github, prefix: "github_"}]

    agent = new_runtime_agent(MCPAgent.runtime_module())

    assert {:ok, _agent, {:ai_react_start, %{}}} =
             Jidoka.MCP.on_before_cmd(agent, {:ai_react_start, %{}}, MCPAgent.mcp_tools())

    assert_received {:mcp_sync_called,
                     %{
                       agent_server: test_pid,
                       endpoint_id: :github,
                       prefix: "github_",
                       replace_existing: false
                     }}

    assert test_pid == self()
  end

  defp operation_surface(agent_module) do
    {agent_module.tools(), agent_module.tool_names()}
  end
end
