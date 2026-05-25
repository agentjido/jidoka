defmodule JidokaTest.SkillsMCPTest do
  use JidokaTest.Support.Case, async: false

  alias Jido.AI.Request

  alias JidokaTest.{
    FailingMCPSync,
    FakeMCPSync,
    InlineMCPAgent,
    LocalFSMCPAgent,
    MCPAgent,
    RuntimeSkillAgent,
    SkillAgent
  }

  @mcp_sandbox Path.expand("../../tmp/mcp-sandbox", __DIR__)

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

  test "module skills contribute action-backed tools to the agent registry" do
    assert SkillAgent.tool_names() == ["multiply_numbers"]
    assert SkillAgent.tools() == [JidokaTest.MultiplyNumbers]
  end

  test "module skills append prompt text through the request transformer" do
    agent = new_runtime_agent(SkillAgent.runtime_module())

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Skill.on_before_cmd(
               agent,
               {:ai_react_start, %{query: "Multiply 6 and 7", tool_context: %{tenant: "demo"}}},
               SkillAgent.skills()
             )

    assert params.allowed_tools == ["multiply_numbers"]
    assert params.tool_context[Jidoka.Skill.context_key()].names == ["module-math-skill"]

    request = react_request([%{role: :user, content: "Multiply 6 and 7"}])
    state = react_state()
    config = react_config(SkillAgent.request_transformer())

    assert {:ok, %{messages: messages}} =
             SkillAgent.request_transformer().transform_request(
               request,
               state,
               config,
               params.tool_context
             )

    assert [%{role: :system, content: system_prompt}, %{role: :user, content: "Multiply 6 and 7"}] =
             messages

    assert system_prompt =~ "You can use skills."
    assert system_prompt =~ "module-math-skill"
    assert system_prompt =~ "multiply_numbers"
  end

  test "runtime skills load from configured paths and narrow allowed tools" do
    agent = new_runtime_agent(RuntimeSkillAgent.runtime_module())

    assert {:ok, _agent, {:ai_react_start, params}} =
             Jidoka.Skill.on_before_cmd(
               agent,
               {:ai_react_start,
                %{
                  query: "Add 17 and 25",
                  allowed_tools: ["add_numbers", "multiply_numbers"],
                  tool_context: %{}
                }},
               RuntimeSkillAgent.skills()
             )

    assert params.allowed_tools == ["add_numbers"]
    assert params.tool_context[Jidoka.Skill.context_key()].names == ["math-discipline"]
    assert params.tool_context[Jidoka.Skill.context_key()].prompt =~ "Math Discipline"
  end

  test "skill load paths are local, expanded, and de-duplicated" do
    assert RuntimeSkillAgent.skills().load_paths == [
             Path.expand("../fixtures/skills", "test/support")
           ]

    assert {:ok, %{refs: ["math-discipline"], load_paths: ["test/fixtures/skills"]}} =
             Jidoka.Skill.normalize_imported(["math-discipline"], [
               "test/fixtures/skills",
               "test/fixtures/skills"
             ])
  end

  test "mcp sync runs once per endpoint per agent" do
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    agent = new_runtime_agent(MCPAgent.runtime_module())

    assert {:ok, agent, {:ai_react_start, %{}}} =
             Jidoka.MCP.on_before_cmd(agent, {:ai_react_start, %{}}, MCPAgent.mcp_tools())

    assert_received {:mcp_sync_called,
                     %{
                       agent_server: test_pid,
                       endpoint_id: :github,
                       prefix: "github_",
                       replace_existing: false
                     }}

    assert test_pid == self()

    assert {:ok, _agent, {:ai_react_start, %{}}} =
             Jidoka.MCP.on_before_cmd(agent, {:ai_react_start, %{}}, MCPAgent.mcp_tools())

    refute_received {:mcp_sync_called, _}
  end

  test "mcp sync metadata is visible in request inspection without a live endpoint" do
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    {:ok, pid} = MCPAgent.start_link(id: "mcp-metadata-agent-test")

    try do
      request_id = "req-mcp-metadata-1"

      :sys.replace_state(pid, fn state ->
        %{state | agent: Request.start_request(state.agent, request_id, "sync mcp")}
      end)

      {:ok, %{agent: agent}} = Jido.AgentServer.state(pid)

      context = %{
        Jidoka.Subagent.server_key() => pid,
        Jidoka.Subagent.request_id_key() => request_id
      }

      assert {:ok, updated_agent, {:ai_react_start, _params}} =
               Jidoka.MCP.on_before_cmd(
                 agent,
                 {:ai_react_start, %{tool_context: context}},
                 MCPAgent.mcp_tools()
               )

      :sys.replace_state(pid, fn state -> %{state | agent: updated_agent} end)

      assert {:ok, summary} = Jidoka.inspect_request(pid)
      assert summary.mcp_tools == ["github:github_"]
      assert summary.mcp_errors == []
    after
      :ok = Jidoka.stop_agent(pid)
    end
  end

  test "runtime MCP endpoints can be registered without application config" do
    with_isolated_mcp_pool(fn ->
      attrs = runtime_endpoint_attrs()

      assert {:ok, endpoint} = Jidoka.MCP.register_endpoint(:runtime_fs, attrs)
      assert endpoint.id == :runtime_fs
      assert :runtime_fs in Jidoka.MCP.endpoint_ids()

      assert {:error, %Jidoka.Error.ExecutionError{} = status_error} =
               Jidoka.MCP.endpoint_status(:runtime_fs)

      assert status_error.message == "MCP endpoint is not started."
      assert status_error.details.reason == :not_started
      assert status_error.details.cause == :not_started

      assert {:error, %Jidoka.Error.ConfigError{} = duplicate_error} =
               Jidoka.MCP.register_endpoint(:runtime_fs, attrs)

      assert duplicate_error.message == "MCP endpoint :runtime_fs is already registered."
      assert duplicate_error.details.reason == :endpoint_already_registered
      assert duplicate_error.details.cause == {:endpoint_already_registered, :runtime_fs}
    end)
  end

  test "runtime MCP endpoint ensure is idempotent and detects conflicts" do
    with_isolated_mcp_pool(fn ->
      attrs = runtime_endpoint_attrs()

      assert {:ok, endpoint} = Jidoka.MCP.ensure_endpoint(:runtime_fs, attrs)
      assert {:ok, ^endpoint} = Jidoka.MCP.ensure_endpoint(:runtime_fs, attrs)

      assert {:error, %Jidoka.Error.ConfigError{} = error} =
               Jidoka.MCP.ensure_endpoint(
                 :runtime_fs,
                 Keyword.put(attrs, :client_info, %{name: "different-test"})
               )

      assert error.message == "MCP endpoint :runtime_fs is already registered with a different definition."
      assert error.details.reason == :endpoint_conflict
      assert {:endpoint_conflict, :runtime_fs, _existing, _incoming} = error.details.cause
    end)
  end

  test "public MCP sync helper supports runtime endpoint attrs" do
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    with_isolated_mcp_pool(fn ->
      assert {:ok, %{registered_count: 1}} =
               Jidoka.MCP.sync_tools(
                 self(),
                 [endpoint: :runtime_sync_fs, prefix: "rt_", replace_existing: false] ++
                   runtime_endpoint_attrs()
               )

      assert :runtime_sync_fs in Jidoka.MCP.endpoint_ids()

      assert_received {:mcp_sync_called,
                       %{
                         agent_server: test_pid,
                         endpoint_id: :runtime_sync_fs,
                         prefix: "rt_",
                         replace_existing: false
                       }}

      assert test_pid == self()
    end)
  end

  test "inline MCP endpoint definitions register before sync" do
    Application.put_env(:jidoka, :mcp_sync_module, FakeMCPSync)

    with_isolated_mcp_pool(fn ->
      agent = new_runtime_agent(InlineMCPAgent.runtime_module())

      assert [
               %{
                 endpoint: :inline_fs,
                 prefix: "inline_",
                 registration: %Jido.MCP.Endpoint{} = registration
               }
             ] = InlineMCPAgent.mcp_tools()

      assert registration.id == :inline_fs
      assert registration.transport == {:stdio, command: "echo"}
      assert registration.timeouts == %{request_ms: 15_000}

      assert {:ok, _agent, {:ai_react_start, %{}}} =
               Jidoka.MCP.on_before_cmd(agent, {:ai_react_start, %{}}, InlineMCPAgent.mcp_tools())

      assert :inline_fs in Jidoka.MCP.endpoint_ids()

      assert_received {:mcp_sync_called,
                       %{
                         endpoint_id: :inline_fs,
                         prefix: "inline_",
                         replace_existing: false
                       }}
    end)
  end

  test "mcp sync failures are recorded without crashing the turn" do
    Application.put_env(:jidoka, :mcp_sync_module, FailingMCPSync)

    agent = new_runtime_agent(MCPAgent.runtime_module())

    assert {:ok, updated_agent, {:ai_react_start, %{tool_context: context}}} =
             Jidoka.MCP.on_before_cmd(
               agent,
               {:ai_react_start, %{tool_context: %{}}},
               MCPAgent.mcp_tools()
             )

    assert_received {:mcp_sync_called,
                     %{
                       endpoint_id: :github,
                       prefix: "github_",
                       replace_existing: false
                     }}

    refute get_in(updated_agent.state, [:__jidoka_mcp__, :synced, {:github, "github_"}])

    assert [
             %{
               endpoint: :github,
               prefix: "github_",
               reason: %Jidoka.Error.ExecutionError{} = error,
               message: "MCP operation failed."
             }
           ] = get_in(updated_agent.state, [:__jidoka_mcp__, :last_errors])

    assert error.details.cause == :server_capabilities_not_set
    assert error.details.target == :github

    assert context == %{}
  end

  @tag :mcp_local
  test "local filesystem MCP endpoint syncs tools into a running Jidoka agent" do
    prepare_mcp_sandbox!()

    {:ok, pid} = LocalFSMCPAgent.start_link(id: "local-fs-mcp-agent-test")

    on_exit(fn ->
      Jidoka.stop_agent(pid)
    end)

    assert LocalFSMCPAgent.mcp_tools() == [%{endpoint: :local_fs, prefix: "fs_"}]

    assert {:ok, result} = capture_mcp_logs(fn -> sync_filesystem_tools(pid) end)

    assert result.discovered_count > 0
    assert result.registered_count > 0
    assert "fs_read_text_file" in result.registered_tools
    assert "fs_list_directory" in result.registered_tools
    assert Enum.any?(result.registered_tools, &String.starts_with?(&1, "fs_"))

    {:ok, %{agent: agent}} = Jido.AgentServer.state(pid)

    action_names =
      agent
      |> get_in([Access.key(:state), Access.key(:__strategy__), Access.key(:config)])
      |> Map.fetch!(:actions_by_name)
      |> Map.keys()

    assert Enum.any?(action_names, &String.starts_with?(&1, "fs_"))
    assert "fs_read_text_file" in action_names
    assert "fs_list_directory" in action_names
  end

  defp prepare_mcp_sandbox! do
    File.rm_rf!(@mcp_sandbox)
    File.mkdir_p!(@mcp_sandbox)
    File.write!(Path.join(@mcp_sandbox, "hello.txt"), "hello from Jidoka MCP test\n")
  end

  defp capture_mcp_logs(fun) do
    ref = make_ref()
    test_pid = self()

    capture_log(fn ->
      send(test_pid, {ref, fun.()})
    end)

    receive do
      {^ref, result} -> result
    after
      0 -> flunk("MCP sync did not return")
    end
  end

  defp sync_filesystem_tools(pid, attempts \\ 10)

  defp sync_filesystem_tools(pid, attempts) do
    case Jidoka.MCP.Sync.run(sync_params(pid), %{}) do
      {:ok, _result} = ok ->
        ok

      {:error, _reason} when attempts > 1 ->
        Process.sleep(250)
        sync_filesystem_tools(pid, attempts - 1)

      error ->
        error
    end
  end

  defp sync_params(pid) do
    %{
      endpoint_id: :local_fs,
      agent_server: pid,
      prefix: "fs_",
      replace_existing: false
    }
  end

  defp runtime_endpoint_attrs do
    [
      transport: {:stdio, command: "echo"},
      client_info: %{name: "jidoka-runtime-test", version: "0.1.0"},
      timeouts: %{request_ms: 15_000}
    ]
  end

  defp with_isolated_mcp_pool(fun) do
    previous_state = :sys.get_state(Jido.MCP.ClientPool)

    try do
      fun.()
    after
      :sys.replace_state(Jido.MCP.ClientPool, fn _state -> previous_state end)
    end
  end
end
