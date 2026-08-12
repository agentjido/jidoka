defmodule Jidoka.CodingPackMutationIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.{MutationPort, Workspace}
  alias Jidoka.Effect
  alias Jidoka.Extension.Host
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.TestSupport.CodingPackMutationBackend, as: Backend
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-mutation-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, backend_state} = Elixir.Agent.start_link(fn -> %{snapshots: %{}} end)
    {:ok, mutation} = MutationPort.new(Backend, state: backend_state)
    workspace = Workspace.new!(root: root, access: [:read, :write])
    request = CodingPack.request()
    {:ok, entry} = CodingPack.entry(workspace, mutation: mutation)

    spec =
      Agent.Spec.new!(
        id: "coding_mutation_agent",
        instructions: "Write the requested file.",
        model: %{provider: :test, id: "model"},
        extensions: [request],
        runtime_defaults: %{max_model_turns: 3}
      )

    {:ok, session} = Session.start(spec, session_id: "coding-mutation-integration")
    {:ok, host} = Host.open(session, [request], %{CodingPack.id() => entry}, :automation)
    {:ok, compiled} = Source.compile(Host.operation_sources(host))
    spec = Agent.Spec.new!(Map.from_struct(spec) |> Map.put(:operations, compiled.operations))

    on_exit(fn ->
      Host.close(host)
      File.rm_rf(root)
    end)

    %{root: root, backend_state: backend_state, spec: spec, capability: compiled.capability}
  end

  test "policy allow runs the mutation without exposing content in the policy resource", context do
    owner = self()

    policy = fn request, _context ->
      if request.effect_class == :operation, do: send(owner, {:resource, request.resource})
      {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")}
    end

    assert {:ok, %Turn.Result{}} =
             Jidoka.turn(context.spec, request(),
               llm: llm(),
               operations: context.capability,
               policy: policy
             )

    assert_receive {:resource,
                    %{
                      "access" => "write",
                      "argument_keys" => ["content", "path"],
                      "arguments" => %{"path" => "result.txt"},
                      "kind" => "coding_workspace",
                      "operation" => "coding.write"
                    }}

    assert File.read!(Path.join(context.root, "result.txt")) == "trusted result"
  end

  test "policy deny stops the mutation capability before checkpoint or write", context do
    owner = self()

    policy = fn request, _context ->
      outcome = if request.effect_class == :operation, do: :deny, else: :allow
      {:ok, Decision.new!(outcome: outcome, rule_id: "test.#{outcome}")}
    end

    operations = fn intent, journal, operation_context ->
      send(owner, :capability_called)
      context.capability.(intent, journal, operation_context)
    end

    assert {:error, %Jidoka.Error.ExecutionError{}} =
             Jidoka.turn(context.spec, request(), llm: llm(), operations: operations, policy: policy)

    refute_receive :capability_called
    refute File.exists?(Path.join(context.root, "result.txt"))
    assert Elixir.Agent.get(context.backend_state, &Map.get(&1, :checkpoint_calls, 0)) == 0
    assert Elixir.Agent.get(context.backend_state, &Map.get(&1, :replace_calls, 0)) == 0
  end

  defp request, do: Turn.Request.new!(input: "Write result.txt")

  defp llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "coding.write",
             arguments: %{"path" => "result.txt", "content" => "trusted result"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Write complete."}}
      end
    end
  end
end
