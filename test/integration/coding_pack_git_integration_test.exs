defmodule Jidoka.CodingPackGitIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{GitPort, ShellPort, Workspace}
  alias Jidoka.Effect
  alias Jidoka.ExecutionEnvironment.{AdapterCapabilities, Manager, PolicyRequest, Registration, SecurityProfile}
  alias Jidoka.Extension.Host
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.TestSupport.CodingPackShellAdapter, as: Adapter
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-git-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, state} = Elixir.Agent.start_link(fn -> %{events: [], responses: [success(" M value.txt\0")]} end)
    profile = profile()
    {:ok, manager} = Manager.start_link(registration(profile), allow_policy(), state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))
    {:ok, shell} = ShellPort.new(manager, binding, profile, %{"git" => %{class: "git"}})
    {:ok, git} = GitPort.new(shell)
    workspace = Workspace.new!(root: root, access: [:read, :git, :shell])
    request = CodingPack.request()
    {:ok, entry} = CodingPack.entry(workspace, git: git)

    spec =
      Agent.Spec.new!(
        id: "coding_git_agent",
        instructions: "Inspect Git status.",
        model: %{provider: :test, id: "model"},
        extensions: [request],
        runtime_defaults: %{max_model_turns: 3}
      )

    {:ok, session} = Session.start(spec, session_id: "coding-git-integration")
    {:ok, host} = Host.open(session, [request], %{CodingPack.id() => entry}, :automation)
    {:ok, compiled} = Source.compile(Host.operation_sources(host))
    spec = Agent.Spec.new!(Map.from_struct(spec) |> Map.put(:operations, compiled.operations))

    on_exit(fn ->
      Host.close(host)
      File.rm_rf(root)
    end)

    %{state: state, spec: spec, capability: compiled.capability}
  end

  test "Git status runs through both policy gates and returns a structured result", context do
    owner = self()

    policy = fn request, _context ->
      if request.effect_class == :operation, do: send(owner, {:resource, request.resource})
      {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")}
    end

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(context.spec, Turn.Request.new!(input: "Inspect status"),
               llm: llm(),
               operations: context.capability,
               policy: policy
             )

    assert_receive {:resource,
                    %{
                      "access" => "git",
                      "arguments" => %{"max_entries" => 5},
                      "operation" => "coding.git_status"
                    }}

    assert [%Effect.OperationResult{output: %{"entries" => [%{"path" => "value.txt"}]}}] =
             result.agent_state.operation_results

    assert [:open, :acquire, {:execute, request}, :close] = events(context.state)
    assert request["command"] == "git"
    assert request["args"] == ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"]
  end

  defp llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "coding.git_status", arguments: %{"max_entries" => 5}}}
        1 -> {:ok, %{type: :final, content: "Status complete."}}
      end
    end
  end

  defp profile do
    SecurityProfile.new!(
      profile_id: "coding-git",
      revision: 1,
      digest: @digest,
      adapter_id: "test.shell",
      required_isolation: :container,
      required_network: :restricted,
      required_workspace: :isolated_copy,
      maximum_limits: %{"wall_time_ms" => 60_000, "output_bytes" => 262_144}
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

  defp success(stdout),
    do: %{"status" => "ok", "stdout" => stdout, "stderr" => "", "exit_status" => 0, "duration_ms" => 1}

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "environment.allow")} end
  end

  defp events(state), do: state |> Elixir.Agent.get(& &1.events) |> Enum.reverse()
end
