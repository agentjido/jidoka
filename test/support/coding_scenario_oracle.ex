defmodule CodingScenario.Oracle do
  @moduledoc false

  @fixture_root Path.expand("../fixtures/coding/rate_limiter/v1", __DIR__)
  @git_env [
    {"GIT_AUTHOR_NAME", "Jidoka Fixture"},
    {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
    {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
    {"GIT_COMMITTER_NAME", "Jidoka Fixture"},
    {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"},
    {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
  ]

  @type fixture :: %{root: String.t(), scenario: map(), revision: String.t()}

  @spec scenario!() :: map()
  def scenario! do
    @fixture_root
    |> Path.join("scenario.json")
    |> File.read!()
    |> Jason.decode!()
    |> validate_scenario!()
  end

  @spec materialize!(String.t()) :: fixture()
  def materialize!(root) do
    scenario = scenario!()
    prepare_empty_root!(root)

    Enum.each(initial_paths(scenario), fn path ->
      copy_fixture_file!(Path.join("repository", path) <> ".fixture", root, path)
    end)

    git!(root, ["init", "-b", "main"])
    git!(root, ["add", "--all"])
    git!(root, ["commit", "--no-gpg-sign", "-m", "Initial rate limiter fixture"], env: @git_env)

    before_digest = tree_digest!(root, initial_paths(scenario), :workspace)

    if before_digest != get_in(scenario, ["digests", "before"]) do
      raise "coding scenario before digest does not match its repository data"
    end

    if status!(root) != [] do
      raise "coding scenario repository is not clean after setup"
    end

    %{root: root, scenario: scenario, revision: git!(root, ["rev-parse", "HEAD"])}
  end

  @spec install_expected!(fixture()) :: fixture()
  def install_expected!(%{root: root, scenario: scenario} = fixture) do
    Enum.each(allowed_paths(scenario), fn path ->
      copy_fixture_file!(Path.join("expected", path) <> ".fixture", root, path)
    end)

    fixture
  end

  @spec valid_operations(map()) :: [map()]
  def valid_operations(scenario \\ scenario!()) do
    get_in(scenario, ["operations", "requirements"])
  end

  @spec expected_claims(fixture()) :: map()
  def expected_claims(%{scenario: scenario}) do
    %{
      "changed_paths" => allowed_paths(scenario),
      "before_digest" => get_in(scenario, ["digests", "before"]),
      "after_digest" => get_in(scenario, ["digests", "after"]),
      "verification" => %{
        "command" => get_in(scenario, ["repository", "required_verification", "command"]),
        "status" => "passed"
      }
    }
  end

  @spec observe!(fixture()) :: map()
  def observe!(%{root: root, scenario: scenario}) do
    paths = initial_paths(scenario)
    entries = status!(root)

    %{
      "changed_paths" => entries |> Enum.map(& &1.path) |> Enum.sort(),
      "staged_paths" => changed_in_column(entries, 0),
      "unstaged_paths" => changed_in_column(entries, 1),
      "branch" => git!(root, ["branch", "--show-current"]),
      "commit_count" => root |> git!(["rev-list", "--count", "HEAD"]) |> String.to_integer(),
      "before_digest" => tree_digest!(root, paths, :head),
      "after_digest" => tree_digest!(root, paths, :workspace),
      "protected_changes" => protected_changes(root, scenario)
    }
  end

  @spec verify(fixture(), [map()], map()) :: {:ok, map()} | {:error, [term()]}
  def verify(fixture, operations, claims) when is_list(operations) and is_map(claims) do
    observed = observe!(fixture)

    errors =
      fixture
      |> preflight_errors(observed, operations, claims)
      |> Enum.uniq()

    case errors do
      [] -> run_verification(fixture, observed)
      _errors -> {:error, errors}
    end
  rescue
    error -> {:error, [{:oracle_observation_failed, Exception.message(error)}]}
  end

  def verify(_fixture, _operations, _claims), do: {:error, [:invalid_oracle_input]}

  defp preflight_errors(%{scenario: scenario}, observed, operations, claims) do
    []
    |> add_error(
      observed["before_digest"] != get_in(scenario, ["digests", "before"]),
      {:before_digest_mismatch, observed["before_digest"]}
    )
    |> add_error(
      observed["after_digest"] != get_in(scenario, ["digests", "after"]),
      {:after_digest_mismatch, observed["after_digest"]}
    )
    |> add_error(
      observed["changed_paths"] != allowed_paths(scenario),
      {:unexpected_changed_paths, observed["changed_paths"]}
    )
    |> add_error(
      observed["protected_changes"] != [],
      {:protected_paths_changed, observed["protected_changes"]}
    )
    |> add_error(not expected_git_state?(observed, scenario), {:git_state_mismatch, git_state(observed)})
    |> Kernel.++(operation_errors(operations, scenario))
    |> Kernel.++(claim_errors(claims, observed, scenario))
  end

  defp expected_git_state?(observed, scenario) do
    expected = scenario["expected_git"]

    observed["branch"] == expected["branch"] and
      observed["commit_count"] == expected["commit_count"] and
      observed["staged_paths"] == expected["staged_paths"] and
      observed["unstaged_paths"] == expected["unstaged_paths"]
  end

  defp git_state(observed) do
    Map.take(observed, ["branch", "commit_count", "staged_paths", "unstaged_paths"])
  end

  defp operation_errors(operations, scenario) do
    requirements = get_in(scenario, ["operations", "requirements"])
    groups = Enum.group_by(operations, & &1["id"])

    requirement_errors =
      Enum.flat_map(requirements, fn required ->
        case Map.get(groups, required["id"], []) do
          [] ->
            [{:missing_operation, required["id"]}]

          [actual] ->
            if Map.take(actual, Map.keys(required)) == required, do: [], else: [{:operation_mismatch, required["id"]}]

          _many ->
            [{:duplicate_operation, required["id"]}]
        end
      end)

    unauthorized_mutations =
      operations
      |> Enum.filter(&(&1["kind"] in ["edit", "write"]))
      |> Enum.map(& &1["path"])
      |> Enum.reject(&(&1 in allowed_paths(scenario)))
      |> Enum.uniq()
      |> Enum.sort()

    order_errors =
      if valid_partial_order?(operations, get_in(scenario, ["operations", "order"])) do
        []
      else
        [:operation_order_violation]
      end

    verification_errors =
      case Enum.filter(operations, &(&1["kind"] == "verify")) do
        [] -> [:missing_verification]
        [_one] -> []
        _many -> [:duplicate_verification]
      end

    requirement_errors ++
      mutation_error(unauthorized_mutations) ++ order_errors ++ verification_errors
  end

  defp mutation_error([]), do: []
  defp mutation_error(paths), do: [{:unauthorized_mutation_operations, paths}]

  defp valid_partial_order?(operations, edges) do
    positions =
      operations
      |> Enum.with_index()
      |> Map.new(fn {operation, index} -> {operation["id"], index} end)

    Enum.all?(edges, fn [before_id, after_id] ->
      case {positions[before_id], positions[after_id]} do
        {before_index, after_index} when is_integer(before_index) and is_integer(after_index) ->
          before_index < after_index

        _missing ->
          false
      end
    end)
  end

  defp claim_errors(claims, observed, scenario) do
    expected = %{
      "changed_paths" => observed["changed_paths"],
      "before_digest" => observed["before_digest"],
      "after_digest" => observed["after_digest"],
      "verification" => %{
        "command" => get_in(scenario, ["repository", "required_verification", "command"]),
        "status" => "passed"
      }
    }

    if claims == expected, do: [], else: [{:model_claim_mismatch, expected, claims}]
  end

  defp run_verification(%{root: root, scenario: scenario}, observed) do
    verification = get_in(scenario, ["repository", "required_verification"])
    [program | args] = verification["argv"]

    task =
      Task.async(fn ->
        System.cmd(program, args,
          cd: root,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, verification["timeout_ms"]) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok,
         Map.merge(observed, %{
           "verification" => %{
             "command" => verification["command"],
             "status" => "passed",
             "output" => output
           }
         })}

      {:ok, {output, status}} ->
        {:error, [{:verification_failed, status, output}]}

      {:exit, reason} ->
        {:error, [{:verification_crashed, reason}]}

      nil ->
        {:error, [{:verification_timeout, verification["timeout_ms"]}]}
    end
  end

  defp protected_changes(root, scenario) do
    scenario
    |> Map.fetch!("repository")
    |> Map.fetch!("protected_paths")
    |> Enum.reject(fn path ->
      case File.read(Path.join(root, path)) do
        {:ok, content} -> content == git!(root, ["show", "HEAD:" <> path], trim: false)
        {:error, _reason} -> false
      end
    end)
    |> Enum.sort()
  end

  defp tree_digest!(root, paths, source) do
    manifest =
      paths
      |> Enum.sort()
      |> Enum.map_join("", fn path ->
        content =
          case source do
            :workspace -> File.read!(Path.join(root, path))
            :head -> git!(root, ["show", "HEAD:" <> path], trim: false)
          end

        path <> <<0>> <> portable_digest(content) <> "\n"
      end)

    portable_digest(manifest)
  end

  defp status!(root) do
    root
    |> git!(["status", "--porcelain=v1", "-z", "--untracked-files=all"], trim: false)
    |> :binary.split(<<0>>, [:global, :trim_all])
    |> Enum.map(fn <<code::binary-size(2), " ", path::binary>> -> %{code: code, path: path} end)
  end

  defp changed_in_column(entries, column) do
    entries
    |> Enum.filter(fn %{code: code} -> binary_part(code, column, 1) != " " end)
    |> Enum.map(& &1.path)
    |> Enum.sort()
  end

  defp copy_fixture_file!(source_relative, destination_root, destination_relative) do
    source = safe_join!(@fixture_root, source_relative)
    destination = safe_join!(destination_root, destination_relative)
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(source, destination)
  end

  defp prepare_empty_root!(root) do
    File.mkdir_p!(root)

    if File.ls!(root) != [] do
      raise "coding scenario destination must be empty"
    end
  end

  defp safe_join!(root, relative) when is_binary(relative) do
    expanded_root = Path.expand(root)
    expanded = Path.expand(relative, expanded_root)

    if Path.type(relative) == :relative and
         (expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/")) do
      expanded
    else
      raise "unsafe coding scenario path: #{inspect(relative)}"
    end
  end

  defp safe_join!(_root, relative), do: raise("unsafe coding scenario path: #{inspect(relative)}")

  defp validate_scenario!(
         %{
           "version" => 1,
           "id" => id,
           "turns" => [_, _, _],
           "repository" => %{
             "initial_files" => files,
             "allowed_changes" => allowed,
             "protected_paths" => protected,
             "required_verification" => %{
               "command" => command,
               "argv" => [program | _args],
               "timeout_ms" => timeout_ms
             }
           },
           "operations" => %{"requirements" => requirements, "order" => order},
           "expected_git" => expected_git,
           "digests" => %{"before" => before_digest, "after" => after_digest}
         } = scenario
       )
       when is_binary(id) and is_list(files) and is_list(allowed) and is_list(protected) and
              is_binary(command) and is_binary(program) and is_integer(timeout_ms) and timeout_ms > 0 and
              is_list(requirements) and is_list(order) and is_map(expected_git) and
              is_binary(before_digest) and is_binary(after_digest) do
    Enum.each(files ++ allowed ++ protected, &safe_join!(@fixture_root, &1))
    scenario
  end

  defp validate_scenario!(_scenario), do: raise("invalid coding scenario data")

  defp initial_paths(scenario), do: get_in(scenario, ["repository", "initial_files"])
  defp allowed_paths(scenario), do: get_in(scenario, ["repository", "allowed_changes"])

  defp portable_digest(content) do
    "sha256:" <> (:crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
  end

  defp add_error(errors, true, error), do: [error | errors]
  defp add_error(errors, false, _error), do: errors

  defp git!(root, args, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    trim? = Keyword.get(opts, :trim, true)
    {output, status} = System.cmd("git", ["-C", root | args], env: env, stderr_to_stdout: true)

    if status == 0 do
      if trim?, do: String.trim(output), else: output
    else
      raise "git command failed with status #{status}: #{output}"
    end
  end
end
