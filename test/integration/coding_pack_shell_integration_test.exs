defmodule Jidoka.CodingPackShellIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{ShellPort, Workspace}
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
    root = Path.join(System.tmp_dir!(), "jidoka-shell-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, state} = Elixir.Agent.start_link(fn -> %{events: []} end)
    profile = profile()
    selection = Jidoka.TestSupport.environment_selection(registration(profile))
    {:ok, manager} = Manager.start_link(selection, allow_policy(), state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))
    {:ok, shell} = ShellPort.new(manager, binding, profile, %{"echo" => %{class: "read"}})
    workspace = Workspace.new!(root: root, access: [:read, :shell])
    request = CodingPack.request()
    {:ok, entry} = CodingPack.entry(workspace, shell: shell)

    spec =
      Agent.Spec.new!(
        id: "coding_shell_agent",
        instructions: "Run the requested command.",
        model: %{provider: :test, id: "model"},
        extensions: [request],
        runtime_defaults: %{max_model_turns: 3}
      )

    {:ok, session} = Session.start(spec, session_id: "coding-shell-integration")
    {:ok, host} = Host.open(session, [request], %{CodingPack.id() => entry}, :automation)
    {:ok, compiled} = Source.compile(Host.operation_sources(host))
    spec = Agent.Spec.new!(Map.from_struct(spec) |> Map.put(:operations, compiled.operations))

    on_exit(fn ->
      Host.close(host)
      File.rm_rf(root)
    end)

    %{state: state, spec: spec, capability: compiled.capability}
  end

  test "policy allow runs the acquired environment without exposing stdin", context do
    owner = self()

    policy = fn request, _context ->
      if request.effect_class == :operation, do: send(owner, {:resource, request.resource})
      {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")}
    end

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(context.spec, request(),
               llm: llm(),
               operations: context.capability,
               policy: policy
             )

    assert_receive {:resource,
                    %{
                      "access" => "shell",
                      "arguments" => %{"command" => "echo", "cwd" => "."},
                      "operation" => "coding.shell"
                    } = resource}

    refute inspect(resource) =~ "private input"

    assert [%Effect.OperationResult{output: %{"stdout" => "private input"}}] =
             result.agent_state.operation_results

    assert [:open, :acquire, {:execute, _request}, :close] = events(context.state)
  end

  test "policy deny stops acquisition and execution", context do
    policy = fn request, _context ->
      outcome = if request.effect_class == :operation, do: :deny, else: :allow
      {:ok, Decision.new!(outcome: outcome, rule_id: "test.#{outcome}")}
    end

    assert {:error, %Jidoka.Error.ExecutionError{}} =
             Jidoka.turn(context.spec, request(),
               llm: llm(),
               operations: context.capability,
               policy: policy
             )

    assert events(context.state) == [:open]
  end

  defp request, do: Turn.Request.new!(input: "Run echo")

  defp llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "coding.shell",
             arguments: %{"command" => "echo", "stdin" => "private input", "cwd" => "."}
           }}

        1 ->
          {:ok, %{type: :final, content: "Command complete."}}
      end
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

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "environment.allow")} end
  end

  defp events(state), do: state |> Elixir.Agent.get(& &1.events) |> Enum.reverse()
end
