defmodule Jidoka.CodingPack.EditTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{Edit, MutationPort, Workspace}
  alias Jidoka.TestSupport.CodingPackMutationBackend, as: Backend

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-edit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, state} = Agent.start_link(fn -> %{snapshots: %{}} end)
    {:ok, port} = MutationPort.new(Backend, state: state)
    on_exit(fn -> File.rm_rf(root) end)

    %{
      root: root,
      state: state,
      port: port,
      workspace: Workspace.new!(root: root, access: [:read, :write])
    }
  end

  test "applies one exact edit and reports structural diff facts", context do
    File.write!(Path.join(context.root, "value.txt"), "alpha\nbefore\nomega\n")

    assert {:ok, result} =
             Edit.run(context.workspace, context.port, %{
               "path" => "value.txt",
               "old_text" => "before",
               "new_text" => "after",
               "expected_occurrences" => 1
             })

    assert File.read!(Path.join(context.root, "value.txt")) == "alpha\nafter\nomega\n"
    assert result["action"] == "edit"
    assert result["diff"]["common_prefix_lines"] == 1
    assert result["diff"]["common_suffix_lines"] == 2
    assert result["diff"]["changed_before_lines"] == 1
    assert result["diff"]["changed_after_lines"] == 1
    refute inspect(result) =~ "alpha\\nbefore\\nomega"
    refute inspect(result) =~ "alpha\\nafter\\nomega"
  end

  test "writes nothing when count or digest guards conflict", context do
    path = Path.join(context.root, "value.txt")
    File.write!(path, "same same")

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_edit_occurrence_mismatch}} =
             Edit.run(context.workspace, context.port, %{
               "path" => "value.txt",
               "old_text" => "same",
               "new_text" => "changed"
             })

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_write_conflict}} =
             Edit.run(context.workspace, context.port, %{
               "path" => "value.txt",
               "old_text" => "same",
               "new_text" => "changed",
               "expected_occurrences" => 2,
               "expected_before_sha256" => "sha256:" <> String.duplicate("0", 64)
             })

    assert File.read!(path) == "same same"
    assert Agent.get(context.state, &Map.get(&1, :replace_calls, 0)) == 0
    assert Agent.get(context.state, &Map.get(&1, :checkpoint_calls, 0)) == 0
  end

  test "rejects missing, ignored, outside, and malformed edits", context do
    File.write!(Path.join(context.root, ".env"), "hidden")

    cases = [
      {%{"path" => "missing", "old_text" => "a", "new_text" => "b"}, :coding_file_not_found},
      {%{"path" => ".env", "old_text" => "hidden", "new_text" => "shown"}, :coding_path_ignored},
      {%{"path" => "../outside", "old_text" => "a", "new_text" => "b"}, :workspace_path_rejected},
      {%{"path" => "value", "old_text" => "", "new_text" => "b"}, :coding_edit_input_invalid}
    ]

    for {arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} =
               Edit.run(context.workspace, context.port, arguments)
    end
  end
end
