defmodule Jidoka.CodingPack.GitTest do
  use ExUnit.Case, async: true

  alias Jidoka.CodingPack.{GitDiff, GitPort, GitStatus, ShellPort, Workspace}
  alias Jidoka.ExecutionEnvironment.{AdapterCapabilities, Manager, PolicyRequest, Registration, SecurityProfile}
  alias Jidoka.Policy.Decision
  alias Jidoka.TestSupport.CodingPackShellAdapter, as: Adapter

  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    root = Path.join(System.tmp_dir!(), "jidoka-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, ".env"), "secret")
    {:ok, state} = Agent.start_link(fn -> %{events: []} end)
    {profile, registration} = environment()
    {:ok, manager} = Manager.start_link(registration, policy(), state: state)
    {:ok, binding, _evidence} = Manager.open(manager, PolicyRequest.new!(profile_id: profile.profile_id))

    {:ok, shell} = ShellPort.new(manager, binding, profile, %{"git" => %{class: "git", mutation: "read"}})
    {:ok, git} = GitPort.new(shell)
    workspace = Workspace.new!(root: root, access: [:read, :git, :shell])
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, state: state, workspace: workspace, git: git}
  end

  test "status returns clean and deterministic staged, unstaged, untracked, and rename facts", context do
    respond(context.state, [success("")])

    assert {:ok, %{"status" => "ok", "clean" => true, "entries" => []}} =
             GitStatus.run(context.workspace, context.git, %{})

    output = " M lib/b.ex\0A  lib/a.ex\0?? lib/new.ex\0R  lib/moved.ex\0lib/old.ex\0 M .env\0"
    respond(context.state, [success(output)])

    assert {:ok, result} = GitStatus.run(context.workspace, context.git, %{"max_entries" => 10})
    assert Enum.map(result["entries"], & &1["path"]) == ["lib/a.ex", "lib/b.ex", "lib/moved.ex", "lib/new.ex"]
    assert Enum.find(result["entries"], &(&1["path"] == "lib/a.ex"))["staged"]
    assert Enum.find(result["entries"], &(&1["path"] == "lib/b.ex"))["unstaged"]
    assert Enum.find(result["entries"], &(&1["path"] == "lib/new.ex"))["untracked"]
    assert Enum.find(result["entries"], &(&1["path"] == "lib/moved.ex"))["original_path"] == "lib/old.ex"
    assert result["omitted_ignored"] == 1
    assert {:ok, _json} = Jason.encode(result)
  end

  test "status enforces path filters and entry limits", context do
    File.write!(Path.join(context.root, "lib/a.ex"), "a")
    output = " M lib/z.ex\0 M lib/a.ex\0"
    respond(context.state, [success(output)])

    assert {:ok, %{"entries" => [%{"path" => "lib/a.ex"}], "omitted_limit" => 1, "truncated" => true}} =
             GitStatus.run(context.workspace, context.git, %{"paths" => ["lib"], "max_entries" => 1})

    assert {:error, %Jidoka.CodingPack.Error{code: :workspace_path_rejected}} =
             GitStatus.run(context.workspace, context.git, %{"paths" => ["../outside"]})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_path_ignored}} =
             GitStatus.run(context.workspace, context.git, %{"paths" => [".env"]})
  end

  test "status reports non-repository and Git errors as distinct portable outcomes", context do
    respond(context.state, [failure("fatal: not a git repository")])

    assert {:ok, %{"status" => "non_repository", "exit_status" => 128}} =
             GitStatus.run(context.workspace, context.git, %{})

    respond(context.state, [failure("fatal: bad revision")])

    assert {:ok, %{"status" => "git_error", "exit_status" => 128}} =
             GitStatus.run(context.workspace, context.git, %{})
  end

  test "diff returns sorted text and binary stats plus bounded patch", context do
    File.write!(Path.join(context.root, "lib/a.ex"), "a")
    File.write!(Path.join(context.root, "image.bin"), <<0>>)

    respond(context.state, [
      success("lib/a.ex\0image.bin\0.env\0"),
      success("1\t2\tlib/a.ex\0-\t-\timage.bin\0"),
      success("diff --git a/lib/a.ex b/lib/a.ex\n+after\n")
    ])

    assert {:ok, result} =
             GitDiff.run(context.workspace, context.git, %{"paths" => ["."], "context_lines" => 1, "max_bytes" => 64})

    assert result["files"] == [
             %{"path" => "image.bin", "binary" => true, "additions" => nil, "deletions" => nil},
             %{"path" => "lib/a.ex", "binary" => false, "additions" => 1, "deletions" => 2}
           ]

    assert result["patch"] =~ "+after"
    assert result["omitted_ignored"] == 1
    assert length(result["executions"]) == 3
    assert {:ok, _json} = Jason.encode(result)
  end

  test "diff handles empty, staged, truncated, non-repository, and invalid requests", context do
    respond(context.state, [success("")])

    assert {:ok, %{"files" => [], "patch" => "", "staged" => true}} =
             GitDiff.run(context.workspace, context.git, %{"staged" => true})

    respond(context.state, [Map.put(success("lib/a.ex\0"), "stdout_truncated", true)])

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_git_path_list_truncated}} =
             GitDiff.run(context.workspace, context.git, %{})

    respond(context.state, [failure("not a git repository")])
    assert {:ok, %{"status" => "non_repository"}} = GitDiff.run(context.workspace, context.git, %{})

    assert {:error, %Jidoka.CodingPack.Error{code: :coding_git_input_invalid}} =
             GitDiff.run(context.workspace, context.git, %{"context_lines" => 21})
  end

  defp environment do
    profile =
      SecurityProfile.new!(
        profile_id: "coding-git",
        revision: 1,
        digest: @digest,
        adapter_id: "test.shell",
        required_isolation: :container,
        required_network: :restricted,
        required_workspace: :isolated_copy,
        maximum_limits: %{"wall_time_ms" => 60_000, "output_bytes" => 262_144}
      )

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

    {profile, Registration.new!(profile: profile, adapter: Adapter, capabilities: capabilities)}
  end

  defp success(stdout),
    do: %{"status" => "ok", "stdout" => stdout, "stderr" => "", "exit_status" => 0, "duration_ms" => 1}

  defp failure(stderr),
    do: %{"status" => "nonzero", "stdout" => "", "stderr" => stderr, "exit_status" => 128, "duration_ms" => 1}

  defp respond(state, responses), do: Agent.update(state, &Map.put(&1, :responses, responses))

  defp policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end
end
