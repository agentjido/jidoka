defmodule Jidoka.CodingPack.RegistrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.Workspace
  alias Jidoka.Extension.Host
  alias Jidoka.Session.Data, as: Session

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-coding-pack-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: Workspace.new!(root: root)}
  end

  test "registers the pack through the public extension host", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, "AGENTS.md"), "trusted project rules")
    assert {:ok, entry} = CodingPack.entry(workspace)
    request = CodingPack.request()

    spec =
      Agent.Spec.new!(
        id: "coding_pack_agent",
        instructions: "Use coding tools.",
        model: %{provider: :test, id: "model"},
        extensions: [request]
      )

    {:ok, session} = Session.start(spec, session_id: "coding-pack-session")
    assert {:ok, host} = Host.open(session, [request], %{CodingPack.id() => entry}, :interactive)

    assert {:ok, %{"jido.coding_pack" => context}} =
             Host.context(host, %{"working_directory" => "."})

    assert context["workspace"]["root_digest"] == workspace.root_digest
    refute inspect(context) =~ workspace.root
    assert [%{"path" => "AGENTS.md"}] = context["instructions"]
    assert {:ok, [%{"status" => "closed"}]} = Host.close(host)
  end

  test "pack and tool registrations can be disabled or replaced by the host", %{workspace: workspace} do
    assert {:ok, entry} = CodingPack.entry(workspace)
    replacement = %{registration: CodingPack.registration(), factory: fn _, _, _ -> {:error, :replacement} end}

    assert Host.registry(%{CodingPack.id() => entry}, %{}, [CodingPack.id()]) == %{}

    assert Host.registry(%{CodingPack.id() => entry}, %{CodingPack.id() => replacement}) == %{
             CodingPack.id() => replacement
           }

    operation = Operation.new!(name: "coding.read", idempotency: :pure)
    original = %{operation: operation, handler: fn _, _ -> {:ok, :original} end}
    changed = %{operation: operation, handler: fn _, _ -> {:ok, :changed} end}

    assert {:ok, %{operations: [%Operation{name: "coding.read"}], handlers: handlers}} =
             CodingPack.compose_tools(%{"coding.read" => original}, %{"coding.read" => changed})

    assert {:ok, :changed} = handlers["coding.read"].(%{}, %{})

    assert {:ok, %{operations: [], handlers: %{}}} =
             CodingPack.compose_tools(%{"coding.read" => original}, %{}, ["coding.read"])
  end

  test "rejects duplicate, unknown, malformed, and agent-configured tools", %{workspace: workspace} do
    operation = Operation.new!(name: "coding.read", idempotency: :pure)
    entry = %{operation: operation, handler: fn _, _ -> :ok end}

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_id_collision}} =
             CodingPack.compose_tools([{"coding.read", entry}, {"coding.read", entry}])

    assert {:error, %Jidoka.CodingPack.Error{code: :unknown_coding_tool_id}} =
             CodingPack.compose_tools(%{"agent.raw_tool" => entry})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_entry_invalid}} =
             CodingPack.compose_tools(%{"coding.read" => %{operation: operation, handler: :not_a_function}})

    assert {:ok, registry_entry} = CodingPack.entry(workspace)
    assert {:error, :coding_pack_agent_config_forbidden} = registry_entry.validate_config.(%{"root" => "/tmp"})
  end

  test "portable workspace and policy summaries do not expose the host root", %{workspace: workspace} do
    File.write!(Path.join(workspace.root, "value.txt"), "value")

    assert {:ok, resource} = Workspace.resource(workspace, "read", "value.txt")
    assert resource["path"] == "value.txt"
    assert resource["workspace"] == workspace.root_digest
    refute inspect(resource) =~ workspace.root
    refute inspect(Workspace.to_map(workspace)) =~ workspace.root
  end
end
