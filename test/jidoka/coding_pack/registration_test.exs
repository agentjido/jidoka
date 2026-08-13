defmodule Jidoka.CodingPack.RegistrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{GitPort, MutationPort, ShellPort, Tools, VerifyPort, Workspace}
  alias Jidoka.Effect
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

    operation = operation("coding.read")
    original = %{operation: operation, handler: fn _, _ -> {:ok, :original} end}
    changed = %{operation: operation, handler: fn _, _ -> {:ok, :changed} end}

    assert {:ok, %{operations: [%Operation{name: "coding.read"}], handlers: handlers}} =
             CodingPack.compose_tools(%{"coding.read" => original}, %{"coding.read" => changed})

    assert {:ok, :changed} = handlers["coding.read"].(%{"path" => "README.md"}, %{})

    assert {:ok, %{operations: [], handlers: %{}}} =
             CodingPack.compose_tools(%{"coding.read" => original}, %{}, ["coding.read"])

    assert {:ok, default_entry} = CodingPack.entry(workspace, disable_tools: ["coding.search"])
    {:ok, session} = Session.start(spec(), session_id: "disabled-search")
    request = CodingPack.request()
    {:ok, host} = Host.open(session, [request], %{CodingPack.id() => default_entry}, :interactive)

    assert Enum.map(Host.operation_sources(host), &Enum.map(&1.operations, fn operation -> operation.name end)) == [
             ["coding.read"]
           ]

    Host.close(host)
  end

  test "all coding tools have valid closed schemas that match valid and invalid inputs", %{workspace: workspace} do
    entries = all_tools(workspace)
    assert Map.keys(entries) |> Enum.sort() == CodingPack.tool_ids() |> Enum.sort()

    Enum.each(entries, fn {name, %{operation: operation}} ->
      schema = operation.metadata["parameters_schema"]
      assert schema["type"] == "object", name
      assert schema["additionalProperties"] == false, name
      root = JSV.build!(schema, warnings: :silent)
      assert {:ok, _input} = JSV.validate(valid_input(name), root, cast: false), name
      assert {:error, _error} = JSV.validate(invalid_input(name, workspace), root, cast: false), name
    end)

    read_schema = entries["coding.read"].operation.metadata["parameters_schema"]
    assert Map.keys(read_schema["properties"]) |> Enum.sort() == ~w(end_line length max_bytes offset path start_line)
    assert {:error, _error} = JSV.validate(%{"path" => "a", "start_line" => 1, "offset" => 0}, JSV.build!(read_schema))
  end

  test "schema validation rejects bad arguments before two-arity and three-arity handlers run" do
    test_pid = self()

    two_arity = %{
      operation: operation("coding.read"),
      handler: fn _arguments, _context -> send(test_pid, :called_two) end
    }

    assert {:ok, %{handlers: %{"coding.read" => wrapped_two}}} =
             CodingPack.compose_tools(%{"coding.read" => two_arity})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_arguments_invalid}} =
             wrapped_two.(%{"path" => ""}, %{})

    refute_received :called_two
    assert :called_two = wrapped_two.(%{path: "README.md"}, %{})
    assert_received :called_two

    three_arity = %{
      operation: operation("coding.edit"),
      handler: fn _intent, _journal, _context -> send(test_pid, :called_three) end
    }

    assert {:ok, %{handlers: %{"coding.edit" => wrapped_three}}} =
             CodingPack.compose_tools(%{"coding.edit" => three_arity})

    invalid = Effect.Intent.new(:operation, %{name: "coding.edit", arguments: %{"path" => "file"}})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_arguments_invalid}} =
             wrapped_three.(invalid, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))

    refute_received :called_three

    valid =
      Effect.Intent.new(:operation, %{
        name: "coding.edit",
        arguments: %{"path" => "file", "old_text" => "before", "new_text" => "after"}
      })

    assert :called_three = wrapped_three.(valid, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
    assert_received :called_three
  end

  test "rejects duplicate, unknown, malformed, and agent-configured tools", %{workspace: workspace} do
    operation = operation("coding.read")
    entry = %{operation: operation, handler: fn _, _ -> :ok end}

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_id_collision}} =
             CodingPack.compose_tools([{"coding.read", entry}, {"coding.read", entry}])

    assert {:error, %Jidoka.CodingPack.Error{code: :unknown_coding_tool_id}} =
             CodingPack.compose_tools(%{"agent.raw_tool" => entry})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_entry_invalid}} =
             CodingPack.compose_tools(%{"coding.read" => %{operation: operation, handler: :not_a_function}})

    missing_schema = Operation.new!(name: "coding.read", idempotency: :pure)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_tool_schema_invalid}} =
             CodingPack.compose_tools(%{
               "coding.read" => %{operation: missing_schema, handler: fn _, _ -> :ok end}
             })

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

  defp spec do
    Agent.Spec.new!(
      id: "coding_pack_registration_agent",
      instructions: "Test.",
      model: %{provider: :test, id: "model"},
      extensions: [CodingPack.request()]
    )
  end

  defp operation(name) do
    Operation.new!(
      name: name,
      idempotency: :pure,
      metadata: %{"parameters_schema" => test_schema(name)}
    )
  end

  defp test_schema("coding.edit") do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "minLength" => 1},
        "old_text" => %{"type" => "string", "minLength" => 1},
        "new_text" => %{"type" => "string"}
      },
      "required" => ["path", "old_text", "new_text"],
      "additionalProperties" => false
    }
  end

  defp test_schema(_name) do
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string", "minLength" => 1}},
      "required" => ["path"],
      "additionalProperties" => false
    }
  end

  defp all_tools(workspace) do
    shell = struct(ShellPort, manager: self(), binding: nil, profile: nil, commands: %{}, opts: [])
    mutation = struct(MutationPort, backend: __MODULE__, opts: [])
    git = struct(GitPort, shell: shell, command: "git")
    verify = struct(VerifyPort, shell: shell, helpers: %{})

    Tools.defaults(workspace, mutation: mutation, shell: shell, git: git, verify: verify)
  end

  defp valid_input("coding.read"), do: %{"path" => "lib/jidoka.ex", "start_line" => 1, "end_line" => 2}
  defp valid_input("coding.search"), do: %{"mode" => "text", "path" => ".", "pattern" => "Jidoka"}
  defp valid_input("coding.write"), do: %{"path" => "new.ex", "content" => "value"}

  defp valid_input("coding.edit"),
    do: %{"path" => "old.ex", "old_text" => "old", "new_text" => "new", "expected_occurrences" => 1}

  defp valid_input("coding.shell"), do: %{"command" => "mix", "args" => ["test"], "cwd" => "."}
  defp valid_input("coding.git_status"), do: %{"paths" => ["lib"], "max_entries" => 10}
  defp valid_input("coding.git_diff"), do: %{"paths" => ["lib"], "context_lines" => 3}
  defp valid_input("coding.verify"), do: %{"helper_id" => "test", "target" => "lib"}

  defp invalid_input("coding.read", workspace),
    do: %{"path" => "file", "max_bytes" => workspace.limits.max_result_bytes + 1}

  defp invalid_input("coding.search", _workspace), do: %{"pattern" => ""}
  defp invalid_input("coding.write", _workspace), do: %{"path" => "file", "content" => "", "extra" => true}
  defp invalid_input("coding.edit", _workspace), do: %{"path" => "file", "old_text" => "", "new_text" => "new"}

  defp invalid_input("coding.shell", workspace),
    do: %{"command" => "mix", "timeout_ms" => workspace.limits.max_shell_timeout_ms + 1}

  defp invalid_input("coding.git_status", _workspace), do: %{"paths" => [""]}
  defp invalid_input("coding.git_diff", _workspace), do: %{"context_lines" => 21}
  defp invalid_input("coding.verify", _workspace), do: %{"helper_id" => "", "edit_ids" => [""]}
end
