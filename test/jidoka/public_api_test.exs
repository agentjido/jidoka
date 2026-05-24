defmodule JidokaTest.PublicAPITest do
  use ExUnit.Case, async: false

  alias Jidoka.ImportedAgent
  alias JidokaTest.Workflow.ToolOnlyWorkflow

  test "top-level runtime entrypoints are exported" do
    Code.ensure_loaded!(Jidoka)
    assert %{fast: _model} = Jidoka.model_aliases()

    assert function_exported?(Jidoka, :chat, 3)
    assert function_exported?(Jidoka, :session, 3)
    assert function_exported?(Jidoka, :start_agent, 2)
    assert function_exported?(Jidoka, :stop_agent, 1)
    assert function_exported?(Jidoka, :whereis, 2)
    assert function_exported?(Jidoka, :list_agents, 1)
    assert function_exported?(Jidoka, :model, 1)
    assert function_exported?(Jidoka, :format_error, 1)

    assert function_exported?(Jidoka.Session, :new, 1)
    assert function_exported?(Jidoka.Session, :chat_opts, 2)
    assert function_exported?(Jidoka.Session, :start_agent, 2)
    assert function_exported?(Jidoka.Session, :snapshot, 2)

    refute function_exported?(Jidoka, :chat_request, 3)
    refute function_exported?(Jidoka, :finalize_chat_request, 3)
    refute function_exported?(Jidoka.Session, :ask, 3)
  end

  test "top-level import and inspection entrypoints are exported" do
    Code.ensure_loaded!(Jidoka)
    assert Jidoka.format_error("loaded") == "loaded"

    assert function_exported?(Jidoka, :import_agent, 2)
    assert function_exported?(Jidoka, :import_agent_file, 2)
    assert function_exported?(Jidoka, :encode_agent, 2)
    assert function_exported?(Jidoka, :inspect_agent, 1)
    assert function_exported?(Jidoka, :inspect_request, 1)
    assert function_exported?(Jidoka, :inspect_trace, 1)
    assert function_exported?(Jidoka, :inspect_trace, 2)
    assert function_exported?(Jidoka, :inspect_workflow, 1)
    assert function_exported?(Jidoka, :handoff_owner, 1)
    assert function_exported?(Jidoka, :reset_handoff, 1)
  end

  test "top-level trace and workflow entrypoints are exported" do
    Code.ensure_loaded!(Jidoka.Trace)
    Code.ensure_loaded!(Jidoka.Workflow)
    assert Jidoka.Trace.list("missing-agent") == {:ok, []}

    assert function_exported?(Jidoka.Trace, :latest, 2)
    assert function_exported?(Jidoka.Trace, :for_request, 3)
    assert function_exported?(Jidoka.Trace, :list, 2)
    assert function_exported?(Jidoka.Trace, :events, 2)
    assert function_exported?(Jidoka.Trace, :spans, 2)
    assert function_exported?(Jidoka.Workflow, :run, 3)

    refute function_exported?(Jidoka, :run, 3)
  end

  test "generated beta entrypoints are exported" do
    Code.ensure_loaded!(JidokaTest.ChatAgent)
    Code.ensure_loaded!(ToolOnlyWorkflow)

    assert JidokaTest.ChatAgent.id() == "chat_agent"
    assert function_exported?(JidokaTest.ChatAgent, :start_link, 1)
    assert function_exported?(JidokaTest.ChatAgent, :chat, 3)
    assert function_exported?(JidokaTest.ChatAgent, :id, 0)

    assert ToolOnlyWorkflow.id() == "tool_only_workflow"
    assert function_exported?(ToolOnlyWorkflow, :run, 2)
    assert function_exported?(ToolOnlyWorkflow, :id, 0)
  end

  test "workflow inspection omits raw Runic graph internals" do
    assert {:ok, inspection} = Jidoka.inspect_workflow(ToolOnlyWorkflow)

    refute Map.has_key?(inspection, :graph)
    refute Map.has_key?(inspection, :node_map)
    refute Map.has_key?(inspection, :execution_summary)
  end

  test "top-level model and error helpers delegate through the public facade" do
    previous = Application.get_env(:jidoka, :model_aliases)
    Application.put_env(:jidoka, :model_aliases, %{unit_model: {:anthropic, model: "claude-test"}})

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:jidoka, :model_aliases)
      else
        Application.put_env(:jidoka, :model_aliases, previous)
      end
    end)

    assert Jidoka.model_aliases() == %{unit_model: {:anthropic, model: "claude-test"}}
    assert Jidoka.model(:unit_model) == {:anthropic, model: "claude-test"}
    assert Jidoka.model("unit_model") == {:anthropic, model: "claude-test"}
    assert Jidoka.format_error(Jidoka.Error.validation_error("Nope.", field: :unit)) == "Nope."
  end

  test "top-level imported-agent helpers support bang and file variants" do
    spec = imported_spec("public_import_agent")

    assert %ImportedAgent{} = agent = Jidoka.import_agent!(spec)
    assert {:ok, encoded} = Jidoka.encode_agent(agent, format: :json)
    assert encoded =~ "\"public_import_agent\""
    assert Jidoka.encode_agent!(agent, format: :json) =~ "\"public_import_agent\""

    path = Path.join(System.tmp_dir!(), "jidoka-public-import-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(spec))

    try do
      assert {:ok, %ImportedAgent{} = file_agent} = Jidoka.import_agent_file(path)
      assert %ImportedAgent{} = Jidoka.import_agent_file!(path)
      assert file_agent.spec.id == "public_import_agent"
    after
      File.rm(path)
    end

    assert_raise ArgumentError, ~r/agent: %{id: \["is required"\]}/, fn ->
      Jidoka.import_agent!(%{"agent" => %{}})
    end
  end

  test "top-level runtime helpers route imported agents and traces" do
    agent = Jidoka.import_agent!(imported_spec("public_runtime_agent"))

    assert {:ok, pid} = Jidoka.start_agent(agent, id: "public-runtime-agent")
    assert Jidoka.whereis("public-runtime-agent") == pid

    assert {:error, _reason} = Jidoka.inspect_trace(pid)
    assert {:error, _reason} = Jidoka.inspect_trace(pid, "missing-request")

    assert :ok = Jidoka.stop_agent(pid)
  end

  defp imported_spec(id) do
    %{
      "agent" => %{"id" => id, "context" => %{}},
      "defaults" => %{"model" => "fast", "instructions" => "You are concise."},
      "capabilities" => %{},
      "lifecycle" => %{}
    }
  end
end
