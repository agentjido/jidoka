defmodule Jidoka.CodingPack.VerifyTest do
  use ExUnit.Case, async: true

  alias Jidoka.Cancellation.Token
  alias Jidoka.CodingPack.{ShellPort, Verify, VerifyPort, Workspace}
  alias Jidoka.ExecutionEnvironment.{AdapterCapabilities, Manager, PolicyRequest, Registration, SecurityProfile}
  alias Jidoka.Policy.Decision
  alias Jidoka.TestSupport.CodingPackShellAdapter, as: Adapter

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-verify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/value_test.exs"), "test")
    File.write!(Path.join(root, ".env"), "secret")
    {:ok, state} = Agent.start_link(fn -> %{events: []} end)
    {profile, registration} = environment()
    selection = Jidoka.TestSupport.environment_selection(registration)
    {:ok, manager} = Manager.start_link(selection, policy(), state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))

    {:ok, shell} =
      ShellPort.new(manager, binding, profile, %{
        "mix" => %{class: "verify", mutation: "read", network: false},
        "online-test" => %{class: "verify", mutation: "read", network: false}
      })

    {:ok, verify} =
      VerifyPort.new(shell, %{
        "unit" => %{
          description: "Run one unit test.",
          command: "mix",
          args: ["test", "{target}"],
          targets: ["test/**/*_test.exs"],
          timeout_ms: 500,
          exit_codes: [0]
        },
        "lint" => %{
          description: "Run the configured linter.",
          command: "mix",
          args: ["lint"],
          timeout_ms: 500,
          exit_codes: [0, 2]
        },
        "online" => %{
          description: "Run an online check.",
          command: "online-test",
          args: [],
          network: true,
          timeout_ms: 500
        }
      })

    workspace = Workspace.new!(root: root, access: [:read, :shell, :verify], limits: %{max_shell_timeout_ms: 1_000})
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, state: state, workspace: workspace, verify: verify}
  end

  test "runs only a trusted helper template and links edit evidence", context do
    assert {:ok, result} =
             Verify.run(context.workspace, context.verify, %{
               "helper_id" => "unit",
               "target" => "test/value_test.exs",
               "edit_ids" => ["edit-1"],
               "checkpoint_ids" => ["checkpoint-1"]
             })

    assert result["status"] == "passed"
    assert result["passed"]
    assert result["helper_id"] == "unit"
    assert result["target"] == "test/value_test.exs"
    assert result["edit_ids"] == ["edit-1"]
    assert result["checkpoint_ids"] == ["checkpoint-1"]

    assert [:open, :acquire, {:execute, request}, :close] = events(context.state)
    assert request["command"] == "mix"
    assert request["args"] == ["test", "test/value_test.exs"]
    assert request["timeout_ms"] == 500
    assert {:ok, _json} = Jason.encode(result)
  end

  test "rejects unknown helpers, unsafe targets, ignored targets, and command injection", context do
    cases = [
      {%{"helper_id" => "unknown"}, :coding_verify_helper_unknown},
      {%{"helper_id" => "unit"}, :coding_verify_target_required},
      {%{"helper_id" => "unit", "target" => "-e"}, :coding_verify_target_unsafe},
      {%{"helper_id" => "unit", "target" => "../outside"}, :workspace_path_rejected},
      {%{"helper_id" => "unit", "target" => ".env"}, :coding_path_ignored},
      {%{"helper_id" => "lint", "target" => "test/value_test.exs"}, :coding_verify_target_forbidden},
      {%{"helper_id" => "unit", "target" => "test/value_test.exs", "command" => "sh"}, :coding_verify_input_invalid}
    ]

    for {arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} =
               Verify.run(context.workspace, context.verify, arguments)
    end

    assert events(context.state) == [:open]
  end

  test "returns passing configured nonzero, failure, timeout, and cancellation states", context do
    respond(context.state, [nonzero(2)])

    assert {:ok, %{"status" => "passed", "passed" => true, "exit_status" => 2}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "lint"})

    respond(context.state, [nonzero(7)])

    assert {:ok, %{"status" => "failed", "passed" => false, "exit_status" => 7}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "lint"})

    Agent.update(context.state, &Map.put(&1, :mode, :timeout))

    assert {:ok, %{"status" => "timeout", "passed" => false}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "lint"})

    token = Token.new()
    Agent.update(context.state, &Map.put(&1, :mode, :cancelled))

    assert {:ok, %{"status" => "cancelled", "passed" => false}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "lint"}, cancellation: token)

    assert Token.requested?(token)
  end

  test "network need and weak evidence fail closed", context do
    assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_network_denied}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "online"})

    Agent.update(context.state, fn state -> Map.put(state, :evidence, %{facts: %{}}) end)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_shell_enforcement_unconfirmed}} =
             Verify.run(context.workspace, context.verify, %{"helper_id" => "lint"})
  end

  test "helper registration rejects raw or invalid templates", context do
    for helpers <- [
          %{"bad" => %{description: "Bad", command: "", args: []}},
          %{"bad" => %{description: "Bad", command: "mix", args: ["{target}"], targets: ["../*"]}},
          %{"bad" => %{description: "Bad", command: "mix", args: [], timeout_ms: 0}},
          %{"bad" => %{description: "Bad", command: "mix", args: [], raw_shell: "mix test"}}
        ] do
      assert {:error, %Jidoka.CodingPack.Error{code: :coding_verify_registration_invalid}} =
               VerifyPort.new(context.verify.shell, helpers)
    end
  end

  defp environment do
    profile =
      SecurityProfile.new!(
        profile_id: "coding-verify",
        revision: 1,
        digest: @digest,
        adapter_id: "test.shell",
        required_isolation: :container,
        required_network: :restricted,
        required_workspace: :isolated_copy,
        maximum_limits: %{"wall_time_ms" => 1_000, "output_bytes" => 262_144}
      )

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

    {profile, Registration.new!(profile: profile, adapter: Adapter, capabilities: capabilities)}
  end

  defp nonzero(code),
    do: %{"status" => "nonzero", "stdout" => "", "stderr" => "failed", "exit_status" => code, "duration_ms" => 1}

  defp respond(state, responses), do: Agent.update(state, &Map.put(&1, :responses, responses))

  defp policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end

  defp events(state), do: state |> Agent.get(& &1.events) |> Enum.reverse()
end
