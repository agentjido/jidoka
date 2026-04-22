defmodule JidokaToolsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Tools.{GitStatus, Grep, ListFiles, Permission, ReadFile}

  test "read-only workspace tools list, read, search, and report git status" do
    workspace = tmp_workspace()
    on_exit(fn -> File.rm_rf!(workspace) end)

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.write!(Path.join(workspace, "README.md"), "hello jidoka\n")
    File.write!(Path.join(workspace, "lib/sample.ex"), "defmodule Sample do\nend\n")
    System.cmd("git", ["init", "-q"], cd: workspace)

    context = %{workspace_path: workspace, permission_mode: :read_only}

    assert {:ok, list_result} = ListFiles.run(%{}, context)
    assert "README.md" in list_result.files
    assert "lib/sample.ex" in list_result.files

    assert {:ok, read_result} = ReadFile.run(%{path: "README.md"}, context)
    assert read_result.contents == "hello jidoka\n"
    assert read_result.truncated == false

    assert {:ok, grep_result} = Grep.run(%{pattern: "defmodule", path: "lib"}, context)
    assert [%{path: "lib/sample.ex", line: 1, text: "defmodule Sample do"}] = grep_result.matches

    assert {:ok, git_result} = GitStatus.run(%{}, context)
    assert git_result.exit_status == 0
    assert git_result.output =~ "##"
  end

  test "read_file refuses paths outside the workspace" do
    parent = tmp_workspace()
    workspace = Path.join(parent, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(parent, "outside.txt"), "outside\n")
    on_exit(fn -> File.rm_rf!(parent) end)

    assert {:error, %{type: :path_outside_workspace}} =
             ReadFile.run(%{path: "../outside.txt"}, %{workspace_path: workspace})
  end

  test "read_file refuses symlinks inside the workspace" do
    parent = tmp_workspace()
    workspace = Path.join(parent, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(parent, "outside.txt"), "outside\n")
    File.ln_s!(Path.join(parent, "outside.txt"), Path.join(workspace, "outside-link.txt"))
    on_exit(fn -> File.rm_rf!(parent) end)

    assert {:error, %{type: :symlink_path}} =
             ReadFile.run(%{path: "outside-link.txt"}, %{workspace_path: workspace})
  end

  test "permission modes enforce the first read-only boundary" do
    assert Permission.allowed?(:read_only, :read)
    refute Permission.allowed?(:read_only, :write)
    assert Permission.allowed?(:workspace_write, :write)
    refute Permission.allowed?(:workspace_write, :danger)
    assert Permission.allowed?(:danger_full_access, :danger)
    assert Permission.allowed?(:allow, :danger)
  end

  defp tmp_workspace do
    Path.join(
      System.tmp_dir!(),
      "jidoka-tools-" <> Integer.to_string(System.unique_integer([:positive]))
    )
  end
end
