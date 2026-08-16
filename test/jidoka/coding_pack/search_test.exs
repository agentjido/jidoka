defmodule Jidoka.CodingPack.SearchTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{Search, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-search-#{System.unique_integer([:positive])}")
    outside = Path.join(System.tmp_dir!(), "jidoka-search-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "src/nested"))
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "z.ex"), "target root\n")
    File.write!(Path.join(root, "src/a.ex"), "first target α\nsecond target\n")
    File.write!(Path.join(root, "src/nested/b.ex"), "TARGET upper\n")
    File.write!(Path.join(root, "src/skip.txt"), "target skipped by glob\n")
    File.write!(Path.join(root, ".env"), "target secret\n")
    File.write!(Path.join(root, "binary.bin"), <<0, 1, 2>>)
    File.write!(Path.join(outside, "secret.ex"), "target outside")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    workspace =
      Workspace.new!(
        root: root,
        limits: %{max_file_bytes: 128, max_result_bytes: 4_096, max_search_results: 20}
      )

    %{root: root, outside: outside, workspace: workspace}
  end

  test "path search is deterministic for root and nested glob matches", %{workspace: workspace} do
    assert {:ok, result} = Search.run(workspace, %{"mode" => "path", "pattern" => "**/*.ex"})

    assert Enum.map(result["matches"], & &1["path"]) == ["src/a.ex", "src/nested/b.ex", "z.ex"]
    assert result["total_count"] == 3
    refute result["truncated"]
    assert {:ok, _json} = Jason.encode(result)

    assert {:ok, nested} =
             Search.run(workspace, %{"mode" => "path", "path" => "src", "pattern" => "*.ex"})

    assert Enum.map(nested["matches"], & &1["path"]) == ["src/a.ex"]
  end

  test "text search returns stable Unicode line and column facts", %{workspace: workspace} do
    assert {:ok, result} =
             Search.run(workspace, %{
               "mode" => "text",
               "pattern" => "target",
               "glob" => "**/*.ex",
               "case_sensitive" => false
             })

    assert Enum.map(result["matches"], &{&1["path"], &1["line"], &1["column"]}) == [
             {"src/a.ex", 1, 7},
             {"src/a.ex", 2, 8},
             {"src/nested/b.ex", 1, 1},
             {"z.ex", 1, 1}
           ]

    assert result["ignored_entries"] >= 1
    assert result["binary_files"] == 0

    assert {:ok, all_files} =
             Search.run(workspace, %{"mode" => "text", "pattern" => "target", "glob" => "**/*"})

    assert all_files["binary_files"] == 1
  end

  test "applies result and output ceilings", %{workspace: workspace} do
    assert {:ok, result} =
             Search.run(workspace, %{
               "mode" => "text",
               "pattern" => "target",
               "max_results" => 1,
               "max_bytes" => 1_024
             })

    assert result["returned_count"] == 1
    assert result["total_count"] > 1
    assert result["truncated"]
  end

  test "loads each ignore file once for one search", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, ".gitignore"), "*.tmp\n")
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    read_rule = fn path ->
      Agent.update(reads, &(&1 + 1))
      File.read(path)
    end

    assert {:ok, _result} =
             Search.run(
               workspace,
               %{"mode" => "path", "pattern" => "**/*"},
               ignore_rule_read_file: read_rule
             )

    assert Agent.get(reads, & &1) == 1
  end

  test "rejects invalid input, unsafe links, and IO failures", %{root: root, outside: outside, workspace: workspace} do
    File.ln_s!(Path.join(outside, "secret.ex"), Path.join(root, "escape.ex"))

    cases = [
      {%{"mode" => "text", "pattern" => ""}, :coding_search_input_invalid},
      {%{"mode" => "path", "pattern" => "[bad"}, :coding_search_glob_invalid},
      {%{"mode" => "path", "pattern" => "*.ex", "path" => "/tmp"}, :workspace_path_rejected},
      {%{"mode" => "text", "pattern" => "target", "max_results" => 21}, :coding_search_input_invalid},
      {%{"mode" => "path", "pattern" => "*.ex"}, :workspace_path_rejected}
    ]

    for {arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} = Search.run(workspace, arguments)
    end

    File.rm!(Path.join(root, "escape.ex"))

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_search_io_error}} =
             Search.run(workspace, %{"mode" => "path", "pattern" => "*"}, list_dir: fn _path -> {:error, :eacces} end)
  end
end
