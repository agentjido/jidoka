defmodule Jidoka.CodingPack.ReadTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{Read, Workspace}

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: Workspace.new!(root: root, limits: %{max_file_bytes: 128, max_result_bytes: 64})}
  end

  test "reads exact line and byte ranges with portable provenance", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, "unicode.txt"), "alpha\nβeta\ngamma\n")

    assert {:ok, result} =
             Read.run(workspace, %{"path" => "unicode.txt", "start_line" => 2, "end_line" => 3})

    assert result["content"] == "βeta\ngamma"
    assert result["range"] == %{"kind" => "lines", "start_line" => 2, "end_line" => 3}
    assert result["size"] == byte_size("alpha\nβeta\ngamma\n")
    assert result["truncated"]
    assert String.starts_with?(result["sha256"], "sha256:")
    assert {:ok, _json} = Jason.encode(result)

    assert {:ok, byte_result} =
             Read.run(workspace, %{"path" => "unicode.txt", "offset" => 0, "length" => 5})

    assert byte_result["content"] == "alpha"
    assert byte_result["range"] == %{"kind" => "bytes", "offset" => 0, "bytes" => 5}
  end

  test "caps output on a UTF-8 boundary", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, "value.txt"), "αβγδε")

    assert {:ok, %{"content" => "αβ", "truncated" => true}} =
             Read.run(workspace, %{"path" => "value.txt", "max_bytes" => 5})
  end

  test "rejects ignored, binary, oversized, missing, outside, and bad ranges", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, ".env"), "TOKEN=secret")
    File.write!(Path.join(root, "binary"), <<0, 1, 2>>)
    File.write!(Path.join(root, "large"), String.duplicate("x", 129))
    File.write!(Path.join(root, "small"), "value")

    cases = [
      {%{"path" => ".env"}, :coding_path_ignored},
      {%{"path" => "binary"}, :coding_file_binary},
      {%{"path" => "large"}, :coding_file_too_large},
      {%{"path" => "missing"}, :coding_file_not_found},
      {%{"path" => "../outside"}, :workspace_path_rejected},
      {%{"path" => "small", "start_line" => 0}, :coding_read_input_invalid},
      {%{"path" => "small", "offset" => 1, "start_line" => 1}, :coding_read_input_invalid},
      {%{"path" => "small", "max_bytes" => 65}, :coding_read_input_invalid}
    ]

    for {arguments, code} <- cases do
      assert {:error, %Jidoka.CodingPack.Error{code: ^code}} = Read.run(workspace, arguments)
    end
  end

  test "returns stable IO and changed-during-read errors", %{root: root, workspace: workspace} do
    path = Path.join(root, "value.txt")
    File.write!(path, "before")

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_read_io_error}} =
             Read.run(workspace, %{"path" => "value.txt"}, read_file: fn _path -> {:error, :eacces} end)

    stat = fn _path ->
      count = Process.get(:read_stat_count, 0)
      Process.put(:read_stat_count, count + 1)
      {:ok, %{size: 6 + count, mtime: count}}
    end

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_file_changed_during_read}} =
             Read.run(workspace, %{"path" => "value.txt"}, stat: stat)
  end

  test "requires trusted read access", %{root: root} do
    File.write!(Path.join(root, "value.txt"), "value")
    workspace = Workspace.new!(root: root, access: [:write])

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_read_denied}} =
             Read.run(workspace, %{"path" => "value.txt"})
  end
end
