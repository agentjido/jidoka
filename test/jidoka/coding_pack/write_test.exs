defmodule Jidoka.CodingPack.WriteTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{MutationPort, Workspace, Write}
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.TestSupport.CodingPackMutationBackend, as: Backend

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-write-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}} end)
    {:ok, port} = MutationPort.new(Backend, state: state)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      state: state,
      port: port,
      workspace: Workspace.new!(root: root, access: [:read, :write], limits: %{max_file_bytes: 64})
    }
  end

  test "creates a file and returns a portable edit record and checkpoint", context do
    assert {:ok, result} =
             Write.run(
               context.workspace,
               context.port,
               %{"path" => "lib/new.txt", "content" => "new value"},
               operation_id: "operation-1"
             )

    assert File.read!(Path.join(context.root, "lib/new.txt")) == "new value"
    assert result["action"] == "create"
    assert result["operation_id"] == "operation-1"
    assert result["before_sha256"] == nil
    assert String.starts_with?(result["after_sha256"], "sha256:")
    assert result["write_method"] == "atomic_replace"
    assert result["checkpoint"]["checkpoint_ref"]
    assert result["diff"]["contains_content"] == false
    refute inspect(result) =~ "new value"
    assert {:ok, _json} = Jason.encode(result)
    assert Agent.get(context.state, & &1.checkpoint_calls) == 1
    assert Agent.get(context.state, & &1.replace_calls) == 1

    assert {:ok, checkpoint} = Checkpoint.new(result["checkpoint"])
    assert {:ok, _evidence} = MutationPort.restore(context.port, context.workspace, checkpoint)
    refute File.exists?(Path.join(context.root, "lib/new.txt"))
  end

  test "requires explicit overwrite and honors the expected digest", context do
    path = Path.join(context.root, "value.txt")
    File.write!(path, "before")

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_write_overwrite_required}} =
             Write.run(context.workspace, context.port, %{"path" => "value.txt", "content" => "after"})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_write_conflict}} =
             Write.run(context.workspace, context.port, %{
               "path" => "value.txt",
               "content" => "after",
               "overwrite" => true,
               "expected_before_sha256" => "sha256:" <> String.duplicate("0", 64)
             })

    assert File.read!(path) == "before"
    refute Map.has_key?(Agent.get(context.state, & &1), :checkpoint_calls)

    expected = digest("before")

    assert {:ok, %{"action" => "replace", "before_sha256" => ^expected}} =
             Write.run(context.workspace, context.port, %{
               "path" => "value.txt",
               "content" => "after",
               "overwrite" => true,
               "expected_before_sha256" => expected
             })

    assert File.read!(path) == "after"
  end

  test "rejects read-only, ignored, outside, binary, and oversized writes before mutation", context do
    read_only = Workspace.new!(root: context.root, access: [:read])

    cases = [
      {read_only, %{"path" => "value", "content" => "value"}, :coding_write_denied},
      {context.workspace, %{"path" => ".env", "content" => "value"}, :coding_path_ignored},
      {context.workspace, %{"path" => "../value", "content" => "value"}, :workspace_path_rejected},
      {context.workspace, %{"path" => "value", "content" => <<0, 1>>}, :coding_write_content_invalid},
      {context.workspace, %{"path" => "value", "content" => String.duplicate("x", 65)}, :coding_file_too_large}
    ]

    for {workspace, arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} =
               Write.run(workspace, context.port, arguments)
    end

    assert Agent.get(context.state, &Map.get(&1, :replace_calls, 0)) == 0
  end

  test "fails closed when write enforcement is not confirmed", context do
    Agent.update(context.state, fn state ->
      Map.put(state, :evidence, %{facts: %{"path_confined" => true, "checkpoint" => true}})
    end)

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_mutation_enforcement_unconfirmed}} =
             Write.run(context.workspace, context.port, %{"path" => "value", "content" => "value"})

    refute File.exists?(Path.join(context.root, "value"))
  end

  test "reports the final state and checkpoint after a partial backend error", context do
    Agent.update(context.state, &Map.put(&1, :mode, :partial_after_write))

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_mutation_failed, details: details}} =
             Write.run(context.workspace, context.port, %{"path" => "value", "content" => "written"})

    assert details.checkpoint["checkpoint_ref"]
    assert details.recovery == "restore_available"
    assert details.final_state["sha256"] == digest("written")
    assert File.read!(Path.join(context.root, "value")) == "written"
  end

  defp digest(value), do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
