defmodule Jidoka.CodingPackReadIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.CodingPack
  alias Jidoka.CodingPack.Workspace
  alias Jidoka.Effect
  alias Jidoka.Extension.Host
  alias Jidoka.Operation.Source
  alias Jidoka.Policy.Decision
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-read-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.txt"), "trusted content")
    on_exit(fn -> File.rm_rf(root) end)

    workspace = Workspace.new!(root: root)
    request = CodingPack.request()
    {:ok, entry} = CodingPack.entry(workspace)

    spec =
      Agent.Spec.new!(
        id: "coding_read_agent",
        instructions: "Read the requested file.",
        model: %{provider: :test, id: "model"},
        extensions: [request],
        runtime_defaults: %{max_model_turns: 3}
      )

    {:ok, session} = Session.start(spec, session_id: "coding-read-integration")
    {:ok, host} = Host.open(session, [request], %{CodingPack.id() => entry}, :automation)
    {:ok, compiled} = Source.compile(Host.operation_sources(host))
    spec = Agent.Spec.new!(Map.from_struct(spec) |> Map.put(:operations, compiled.operations))
    on_exit(fn -> Host.close(host) end)
    %{spec: spec, capability: compiled.capability}
  end

  test "read operation runs after policy allow with a bounded resource summary", context do
    owner = self()

    policy = fn request, _context ->
      if request.effect_class == :operation, do: send(owner, {:resource, request.resource})
      {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")}
    end

    operations = fn intent, journal, operation_context ->
      send(owner, :capability_called)
      context.capability.(intent, journal, operation_context)
    end

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.turn(context.spec, request(),
               llm: llm(),
               operations: operations,
               policy: policy
             )

    assert_receive {:resource,
                    %{
                      "access" => "read",
                      "arguments" => %{"path" => "note.txt"},
                      "kind" => "coding_workspace",
                      "operation" => "coding.read"
                    }}

    assert_receive :capability_called

    assert [%Effect.OperationResult{output: %{"content" => "trusted content"}}] =
             result.agent_state.operation_results
  end

  test "policy deny stops the read capability", context do
    owner = self()

    policy = fn request, _context ->
      outcome = if request.effect_class == :operation, do: :deny, else: :allow
      {:ok, Decision.new!(outcome: outcome, rule_id: "test.#{outcome}")}
    end

    operations = fn intent, journal, operation_context ->
      send(owner, :capability_called)
      context.capability.(intent, journal, operation_context)
    end

    assert {:error, %Jidoka.Error.ExecutionError{details: details}} =
             Jidoka.turn(context.spec, request(),
               llm: llm(),
               operations: operations,
               policy: policy
             )

    assert inspect(details) =~ "policy_denied"
    refute_receive :capability_called
  end

  defp request, do: Turn.Request.new!(input: "Read note.txt")

  defp llm do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "coding.read", arguments: %{"path" => "note.txt"}}}
        1 -> {:ok, %{type: :final, content: "Read complete."}}
      end
    end
  end
end
