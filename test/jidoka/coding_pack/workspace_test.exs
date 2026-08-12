defmodule Jidoka.CodingPack.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{Ignore, Instructions, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-workspace-#{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "jidoka-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "src/nested"))
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    %{root: root, outside: outside}
  end

  test "resolves canonical paths and rejects every workspace escape", %{root: root, outside: outside} do
    File.write!(Path.join(root, "src/file.txt"), "safe")
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "escape"))
    File.ln_s!(Path.join(root, "src/file.txt"), Path.join(root, "inside"))
    workspace = Workspace.new!(root: root)

    assert {:ok, %{relative: "src/file.txt", type: :regular}} =
             Workspace.resolve(workspace, "src/file.txt", type: :regular)

    assert {:ok, %{relative: "src/file.txt"}} = Workspace.resolve(workspace, "inside")

    for path <- ["../secret.txt", Path.join(outside, "secret.txt"), "escape"] do
      assert {:error, %Jidoka.CodingPack.Error{code: :workspace_path_rejected}} =
               Workspace.resolve(workspace, path)
    end

    assert {:ok, %{relative: "src/new.txt", type: :missing}} =
             Workspace.resolve(workspace, "src/new.txt", allow_missing: true)
  end

  test "rejects missing roots, file roots, invalid encoding, and special files", %{root: root} do
    file = Path.join(root, "file-root")
    File.write!(file, "file")

    assert {:error, %Jidoka.CodingPack.Error{code: :workspace_invalid}} =
             Workspace.new(root: Path.join(root, "missing"))

    assert {:error, %Jidoka.CodingPack.Error{code: :workspace_invalid}} = Workspace.new(root: file)

    workspace = Workspace.new!(root: root)

    assert {:error, %Jidoka.CodingPack.Error{code: :workspace_path_rejected}} =
             Workspace.resolve(workspace, <<255>>)

    if match?({:unix, _}, :os.type()) do
      fifo = Path.join(root, "pipe")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert {:error, %Jidoka.CodingPack.Error{code: :workspace_path_rejected}} =
               Workspace.resolve(workspace, "pipe")
    end
  end

  test "applies trusted exclusions and nested ignore rules in stable order", %{root: root} do
    File.write!(Path.join(root, ".gitignore"), "*.log\n!keep.log\nprivate/\n")
    File.write!(Path.join(root, "src/.gitignore"), "!visible.log\n")

    for path <- ["error.log", "keep.log", ".env", "src/visible.log", "src/hidden.log"] do
      File.write!(Path.join(root, path), "data")
    end

    File.mkdir_p!(Path.join(root, "private"))
    File.write!(Path.join(root, "private/value.txt"), "data")
    workspace = Workspace.new!(root: root)

    assert {:ok, %{ignored?: true, source: ".gitignore", pattern: "*.log"}} =
             Ignore.decision(workspace, "error.log")

    assert {:ok, %{ignored?: false, pattern: "!keep.log"}} = Ignore.decision(workspace, "keep.log")
    assert {:ok, %{ignored?: false, source: "src/.gitignore"}} = Ignore.decision(workspace, "src/visible.log")
    assert {:ok, %{ignored?: true}} = Ignore.decision(workspace, "src/hidden.log")
    assert {:ok, %{ignored?: true, kind: "trusted_exclusion"}} = Ignore.decision(workspace, ".env")
    assert {:ok, %{ignored?: true, pattern: "private"}} = Ignore.decision(workspace, "private/value.txt")
  end

  test "rejects bad ignore patterns", %{root: root} do
    File.write!(Path.join(root, ".gitignore"), "[bad\n")
    File.write!(Path.join(root, "value.txt"), "data")
    workspace = Workspace.new!(root: root)

    assert {:error, %Jidoka.CodingPack.Error{code: :ignore_rules_invalid}} =
             Ignore.decision(workspace, "value.txt")
  end

  test "discovers bounded instructions from root to selected directory", %{root: root} do
    File.write!(Path.join(root, "AGENTS.md"), "root rules")
    File.write!(Path.join(root, "src/AGENTS.md"), "source rules")
    File.write!(Path.join(root, "src/nested/AGENTS.md"), "nested rules")
    workspace = Workspace.new!(root: root, instruction_files: ["AGENTS.md"])

    assert {:ok, instructions} = Instructions.discover(workspace, "src/nested")
    assert Enum.map(instructions, & &1["path"]) == ["AGENTS.md", "src/AGENTS.md", "src/nested/AGENTS.md"]
    assert Enum.map(instructions, & &1["content"]) == ["root rules", "source rules", "nested rules"]
    assert Enum.all?(instructions, &String.starts_with?(&1["sha256"], "sha256:"))
  end

  test "rejects oversized and ignored instruction files", %{root: root} do
    File.write!(Path.join(root, ".gitignore"), "src/AGENTS.md\n")
    File.write!(Path.join(root, "AGENTS.md"), "12345")
    File.write!(Path.join(root, "src/AGENTS.md"), "ignored")

    workspace =
      Workspace.new!(
        root: root,
        instruction_files: ["AGENTS.md"],
        limits: %{max_instruction_bytes: 5}
      )

    assert {:ok, [%{"path" => "AGENTS.md"}]} = Instructions.discover(workspace, "src")

    File.write!(Path.join(root, "AGENTS.md"), "123456")

    assert {:error, %Jidoka.CodingPack.Error{code: :instruction_too_large}} =
             Instructions.discover(workspace, ".")
  end
end
