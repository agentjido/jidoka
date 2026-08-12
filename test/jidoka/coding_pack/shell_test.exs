defmodule Jidoka.CodingPack.ShellTest do
  use ExUnit.Case, async: true

  alias Jidoka.Cancellation.Token
  alias Jidoka.CodingPack.{Shell, ShellPort, Workspace}
  alias Jidoka.ExecutionEnvironment.{AdapterCapabilities, Manager, PolicyRequest, Registration, SecurityProfile}
  alias Jidoka.Policy.Decision
  alias Jidoka.TestSupport.CodingPackShellAdapter, as: Adapter

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-shell-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "subdir"))
    {:ok, state} = Agent.start_link(fn -> %{events: []} end)
    profile = profile()
    {:ok, manager} = Manager.start_link(registration(profile), allow_policy(), state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))

    {:ok, port} =
      ShellPort.new(
        manager,
        binding,
        profile,
        %{
          "echo" => %{class: "read", mutation: "read", network: false},
          "fetch" => %{class: "network", mutation: "write", network: true}
        }
      )

    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      state: state,
      manager: manager,
      port: port,
      workspace:
        Workspace.new!(
          root: root,
          access: [:read, :shell],
          limits: %{
            max_shell_args: 3,
            max_shell_stdin_bytes: 16,
            max_shell_output_bytes: 32,
            max_shell_timeout_ms: 1_000
          }
        )
    }
  end

  test "runs a registered command with bounded separate output and confirmed evidence", context do
    assert {:ok, result} =
             Shell.run(context.workspace, context.port, %{
               "command" => "echo",
               "args" => ["one", "two"],
               "stdin" => "input:",
               "cwd" => "subdir",
               "timeout_ms" => 25,
               "max_output_bytes" => 16
             })

    assert result["status"] == "ok"
    assert result["stdout"] == "input:one two"
    assert result["stderr"] == "diagnostic"
    assert result["exit_status"] == 0
    assert result["backend"] == "fake-shell"
    assert result["enforcement"]["facts"]["shell_execute"]
    assert result["cleanup"]["status"] == "confirmed"
    assert {:ok, _json} = Jason.encode(result)

    assert [:open, :acquire, {:execute, request}, :close] = events(context.state)
    assert request["command"] == "echo"
    assert request["command_class"] == "read"
    assert request["mutation"] == "read"
    assert request["cwd"] == "subdir"
  end

  test "rejects invalid input, cwd, command, network, and workspace access before execution", context do
    read_only = Workspace.new!(root: context.root, access: [:read])

    cases = [
      {context.workspace, %{"command" => ""}, :coding_shell_input_invalid},
      {context.workspace, %{"command" => "echo", "args" => ["a", "b", "c", "d"]}, :coding_shell_input_invalid},
      {context.workspace, %{"command" => "echo", "stdin" => String.duplicate("x", 17)}, :coding_shell_input_invalid},
      {context.workspace, %{"command" => "echo", "timeout_ms" => 1_001}, :coding_shell_input_invalid},
      {context.workspace, %{"command" => "echo", "cwd" => "../outside"}, :workspace_path_rejected},
      {context.workspace, %{"command" => "unknown"}, :coding_shell_command_denied},
      {context.workspace, %{"command" => "echo", "network" => true}, :coding_shell_network_denied},
      {read_only, %{"command" => "echo"}, :coding_shell_denied}
    ]

    for {workspace, arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} =
               Shell.run(workspace, context.port, arguments)
    end

    assert events(context.state) == [:open]
  end

  test "normalizes nonzero, timeout, cancelled, truncated, adapter, and cleanup outcomes", context do
    cases = [
      {:nonzero, %{"status" => "nonzero", "exit_status" => 7}},
      {:timeout, %{"status" => "timeout", "exit_status" => nil}},
      {:oversized, %{"status" => "ok", "stdout_truncated" => true, "stderr_truncated" => true}}
    ]

    for {mode, expected} <- cases do
      Agent.update(context.state, &Map.put(&1, :mode, mode))
      assert {:ok, result} = Shell.run(context.workspace, context.port, %{"command" => "echo"})
      assert Map.take(result, Map.keys(expected)) == expected
      assert byte_size(result["stdout"]) <= 32
      assert byte_size(result["stderr"]) <= 32
    end

    token = Token.new()
    Agent.update(context.state, &Map.put(&1, :mode, :cancelled))

    assert {:ok, %{"status" => "cancelled"}} =
             Shell.run(context.workspace, context.port, %{"command" => "echo"}, cancellation: token)

    assert Token.requested?(token)

    for mode <- [:adapter_error, :close_error] do
      Agent.update(context.state, &Map.put(&1, :mode, mode))

      assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_environment_failed}} =
               Shell.run(context.workspace, context.port, %{"command" => "echo"})
    end

    assert Enum.count(events(context.state), &(&1 == :close)) == 6
  end

  test "fails closed after execution when shell evidence or limits are weaker", context do
    Agent.update(context.state, fn state -> Map.put(state, :evidence, %{facts: %{}}) end)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_enforcement_unconfirmed}} =
             Shell.run(context.workspace, context.port, %{"command" => "echo"})

    Agent.update(context.state, fn state ->
      Map.put(state, :evidence, %{applied_limits: %{"wall_time_ms" => 100, "output_bytes" => 32}})
    end)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_enforcement_unconfirmed}} =
             Shell.run(context.workspace, context.port, %{"command" => "echo", "timeout_ms" => 25})

    assert Enum.count(events(context.state), &(&1 == :close)) == 2
  end

  test "a manager policy denial prevents adapter execution and still closes the handle", context do
    profile = profile()

    policy = fn request, _context ->
      outcome = if request.action == "execute", do: :deny, else: :allow
      {:ok, Decision.new!(outcome: outcome, rule_id: "test.#{outcome}")}
    end

    {:ok, state} = Agent.start_link(fn -> %{events: []} end)
    {:ok, manager} = Manager.start_link(registration(profile), policy, state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))
    {:ok, port} = ShellPort.new(manager, binding, profile, %{"echo" => %{class: "read"}})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_environment_failed}} =
             Shell.run(context.workspace, port, %{"command" => "echo"})

    assert events(state) == [:open, :acquire, :close]
  end

  test "shell source has no direct host execution fallback" do
    source = File.read!("lib/jidoka/coding_pack/shell.ex")
    port_source = File.read!("lib/jidoka/coding_pack/shell_port.ex")

    for forbidden <- ["System.cmd", "Port.open", ":open_port", "Task.async"] do
      refute source =~ forbidden
      refute port_source =~ forbidden
    end
  end

  defp profile do
    SecurityProfile.new!(
      profile_id: "coding-shell",
      revision: 1,
      digest: @digest,
      adapter_id: "test.shell",
      required_isolation: :container,
      required_network: :restricted,
      required_workspace: :isolated_copy,
      maximum_limits: %{"wall_time_ms" => 1_000, "output_bytes" => 32}
    )
  end

  defp registration(profile) do
    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.shell",
        adapter_version: "1",
        isolations: [:container],
        networks: [:restricted],
        workspaces: [:isolated_copy],
        limit_keys: ["wall_time_ms", "output_bytes"],
        capability_ids: ["shell.execute"]
      )

    Registration.new!(profile: profile, adapter: Adapter, capabilities: capabilities)
  end

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end

  defp events(state), do: state |> Agent.get(& &1.events) |> Enum.reverse()
end
