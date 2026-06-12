defmodule JidokaToolsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Tools.{
    EditFile,
    GitDiff,
    GitStatus,
    Grep,
    ListFiles,
    MixCheck,
    MixTest,
    Permission,
    ReadFile,
    WriteFile
  }

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

  test "write_file requires workspace write permission and writes text files inside the workspace" do
    workspace = tmp_workspace()
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    read_only_context = %{workspace_path: workspace, permission_mode: :read_only}
    write_context = %{workspace_path: workspace, permission_mode: :workspace_write}

    assert {:error, %{type: :permission_denied}} =
             WriteFile.run(%{path: "note.txt", contents: "hello\n"}, read_only_context)

    assert {:ok, result} = WriteFile.run(%{path: "note.txt", contents: "hello\n"}, write_context)
    assert result.path == "note.txt"
    assert File.read!(Path.join(workspace, "note.txt")) == "hello\n"
  end

  test "write_file rejects blocked directories, outside paths, symlinks, and binary targets" do
    parent = tmp_workspace()
    workspace = Path.join(parent, "workspace")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "deps"))
    File.write!(Path.join(parent, "outside.txt"), "outside\n")
    File.write!(Path.join(workspace, "binary.bin"), <<0xFF, 0xFE>>)
    File.ln_s!(Path.join(parent, "outside.txt"), Path.join(workspace, "outside-link.txt"))
    on_exit(fn -> File.rm_rf!(parent) end)

    context = %{workspace_path: workspace, permission_mode: :workspace_write}

    assert {:error, %{type: :path_outside_workspace}} =
             WriteFile.run(%{path: "../outside.txt", contents: "bad\n"}, context)

    assert {:error, %{type: :blocked_path}} =
             WriteFile.run(%{path: "deps/new.txt", contents: "bad\n"}, context)

    assert {:error, %{type: :symlink_path}} =
             WriteFile.run(%{path: "outside-link.txt", contents: "bad\n"}, context)

    assert {:error, %{type: :binary_file}} =
             WriteFile.run(%{path: "binary.bin", contents: "bad\n"}, context)
  end

  test "edit_file applies bounded replacements and invalid patches do not modify files" do
    workspace = tmp_workspace()
    File.mkdir_p!(workspace)
    file_path = Path.join(workspace, "note.txt")
    File.write!(file_path, "alpha\nbeta\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    context = %{workspace_path: workspace, permission_mode: :workspace_write}

    assert {:error, %{type: :patch_search_not_found}} =
             EditFile.run(
               %{path: "note.txt", search: "missing", replacement: "gamma"},
               context
             )

    assert File.read!(file_path) == "alpha\nbeta\n"

    assert {:ok, result} =
             EditFile.run(
               %{path: "note.txt", search: "beta", replacement: "gamma"},
               context
             )

    assert result.replacements == 1
    assert File.read!(file_path) == "alpha\ngamma\n"
  end

  test "mix_test and mix_check run allowlisted project commands only with workspace write permission" do
    workspace = tmp_mix_project()
    on_exit(fn -> File.rm_rf!(workspace) end)

    read_only_context = %{workspace_path: workspace, permission_mode: :read_only}
    write_context = %{workspace_path: workspace, permission_mode: :workspace_write}

    assert {:error, %{type: :permission_denied}} = MixTest.run(%{}, read_only_context)

    assert {:ok, test_result} = MixTest.run(%{target: "test/sample_test.exs"}, write_context)
    assert test_result.exit_status == 0
    assert test_result.output =~ ~r/(1 test, 0 failures|1 passed)/

    assert {:ok, check_result} =
             MixCheck.run(%{checks: ["test"], timeout_ms: 120_000}, write_context)

    assert check_result.status == :passed
    assert [%{check: :test, exit_status: 0}] = check_result.steps
  end

  test "git_diff exposes read-only git views without arbitrary shell" do
    workspace = tmp_workspace()
    on_exit(fn -> File.rm_rf!(workspace) end)

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "hello\n")
    System.cmd("git", ["init", "-q"], cd: workspace)
    System.cmd("git", ["config", "user.email", "jidoka@example.invalid"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Jidoka Test"], cd: workspace)
    System.cmd("git", ["add", "README.md"], cd: workspace)
    System.cmd("git", ["commit", "-q", "-m", "initial"], cd: workspace)
    File.write!(Path.join(workspace, "README.md"), "hello jidoka\n")

    assert {:ok, result} =
             GitDiff.run(%{mode: "diff", path: "README.md"}, %{
               workspace_path: workspace,
               permission_mode: :read_only
             })

    assert result.exit_status == 0
    assert result.output =~ "-hello"
    assert result.output =~ "+hello jidoka"
    refute Code.ensure_loaded?(Jidoka.Tools.Shell)
  end

  defp tmp_workspace do
    Path.join(
      System.tmp_dir!(),
      "jidoka-tools-" <> Integer.to_string(System.unique_integer([:positive]))
    )
  end

  defp tmp_mix_project do
    workspace = tmp_workspace()
    File.mkdir_p!(Path.join(workspace, "test"))

    File.write!(
      Path.join(workspace, "mix.exs"),
      """
      defmodule Sample.MixProject do
        use Mix.Project

        def project do
          [app: :sample, version: "0.1.0", elixir: "~> 1.19", deps: []]
        end
      end
      """
    )

    File.write!(Path.join(workspace, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(workspace, "test/sample_test.exs"),
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "sample" do
          assert 1 + 1 == 2
        end
      end
      """
    )

    workspace
  end
end
