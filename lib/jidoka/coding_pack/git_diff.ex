defmodule Jidoka.CodingPack.GitDiff do
  @moduledoc "Structured bounded Git diff through a constrained environment."

  alias Jidoka.CodingPack.{Error, Git, GitPort, Workspace}

  @keys ~w(paths staged context_lines max_bytes)

  @doc "Returns the model-visible Git diff operation and handler."
  @spec tool(Workspace.t(), GitPort.t()) :: %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %GitPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.git_diff",
          description: "Return a structured bounded Git diff without changing repository state.",
          idempotency: :pure,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "git",
              "argument_fields" => ["paths", "staged", "context_lines", "max_bytes"]
            }
          }
        ),
      handler: fn arguments, _context -> run(workspace, port, arguments) end
    }
  end

  @doc "Returns deterministic file statistics and a bounded patch for visible paths."
  @spec run(Workspace.t(), GitPort.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %GitPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with true <- Workspace.permits?(workspace, :git),
         {:ok, input} <- input(arguments, workspace),
         {:ok, filters} <- Git.filters(workspace, input.paths),
         {:ok, names_shell} <- names(port, workspace, input, filters, opts) do
      diff_result(port, workspace, input, names_shell, opts)
    else
      false -> {:error, Error.new(:coding_git_denied, %{reason: :workspace_access})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, %GitPort{}, _arguments, _opts), do: {:error, Error.new(:coding_git_input_invalid)}

  defp names(port, workspace, input, filters, opts) do
    GitPort.run(
      port,
      workspace,
      base_args(input) ++ ["--name-only", "-z", "--diff-filter=ACDMRTUXB", "--" | filters],
      Keyword.merge(opts, max_output_bytes: workspace.limits.max_shell_output_bytes)
    )
  end

  defp diff_result(port, workspace, input, names_shell, opts) do
    case Git.command_outcome(names_shell) do
      {:ok, %{"stdout_truncated" => true}} ->
        {:error, Error.new(:coding_git_path_list_truncated)}

      {:ok, names_shell} ->
        limit = max(workspace.limits.max_shell_args - 8, 1)

        {paths, omitted_ignored, omitted_limit} =
          Git.visible_paths(workspace, Git.nul_paths(names_shell["stdout"]), limit)

        if paths == [] do
          {:ok, empty_result(names_shell, input, omitted_ignored, omitted_limit)}
        else
          execute_diff(port, workspace, input, paths, names_shell, omitted_ignored, omitted_limit, opts)
        end

      {:outcome, result} ->
        {:ok, Map.drop(result, ["stdout"])}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_diff(port, workspace, input, paths, names_shell, omitted_ignored, omitted_limit, opts) do
    with {:ok, stats_shell} <-
           GitPort.run(
             port,
             workspace,
             base_args(input) ++ ["--numstat", "-z", "--" | paths],
             Keyword.merge(opts, max_output_bytes: workspace.limits.max_shell_output_bytes)
           ),
         {:ok, stats_shell} <- successful(stats_shell),
         {:ok, patch_shell} <-
           GitPort.run(
             port,
             workspace,
             base_args(input) ++ ["--no-color", "--no-ext-diff", "--unified=#{input.context_lines}", "--" | paths],
             Keyword.merge(opts, max_output_bytes: input.max_bytes)
           ),
         {:ok, patch_shell} <- successful(patch_shell) do
      files = parse_stats(stats_shell["stdout"]) |> Enum.sort_by(& &1["path"])

      {:ok,
       %{
         "status" => "ok",
         "staged" => input.staged,
         "files" => files,
         "patch" => patch_shell["stdout"],
         "truncated" => patch_shell["stdout_truncated"] or omitted_limit > 0,
         "omitted_ignored" => omitted_ignored,
         "omitted_limit" => omitted_limit,
         "stderr" => patch_shell["stderr"],
         "backend" => patch_shell["backend"],
         "enforcement" => patch_shell["enforcement"],
         "cleanup" => patch_shell["cleanup"],
         "executions" => Enum.map([names_shell, stats_shell, patch_shell], &execution/1)
       }}
    else
      {:outcome, result} -> {:ok, Map.drop(result, ["stdout"])}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp successful(shell) do
    case Git.command_outcome(shell) do
      {:ok, shell} -> {:ok, shell}
      other -> other
    end
  end

  defp empty_result(shell, input, omitted_ignored, omitted_limit) do
    %{
      "status" => "ok",
      "staged" => input.staged,
      "files" => [],
      "patch" => "",
      "truncated" => omitted_limit > 0,
      "omitted_ignored" => omitted_ignored,
      "omitted_limit" => omitted_limit,
      "stderr" => shell["stderr"],
      "backend" => shell["backend"],
      "enforcement" => shell["enforcement"],
      "cleanup" => shell["cleanup"],
      "executions" => [execution(shell)]
    }
  end

  defp parse_stats(value) do
    value
    |> String.split(<<0>>, trim: true)
    |> Enum.flat_map(fn token ->
      case String.split(token, "\t", parts: 3) do
        ["-", "-", path] -> [%{"path" => path, "binary" => true, "additions" => nil, "deletions" => nil}]
        [added, deleted, path] -> numeric_stat(path, added, deleted)
        _invalid -> []
      end
    end)
  end

  defp numeric_stat(path, added, deleted) do
    with {added, ""} <- Integer.parse(added),
         {deleted, ""} <- Integer.parse(deleted) do
      [%{"path" => path, "binary" => false, "additions" => added, "deletions" => deleted}]
    else
      _error -> []
    end
  end

  defp execution(shell),
    do: %{
      "status" => shell["status"],
      "duration_ms" => shell["duration_ms"],
      "backend" => shell["backend"],
      "enforcement" => shell["enforcement"],
      "cleanup" => shell["cleanup"]
    }

  defp base_args(%{staged: true}), do: ["diff", "--cached"]
  defp base_args(%{staged: false}), do: ["diff"]

  defp input(arguments, workspace) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    paths = Map.get(arguments, "paths", [])
    staged = Map.get(arguments, "staged", false)
    context = Map.get(arguments, "context_lines", 3)
    max_bytes = Map.get(arguments, "max_bytes", workspace.limits.max_result_bytes)

    if unknown == [] and is_list(paths) and is_boolean(staged) and valid_context?(context) and
         valid_max_bytes?(max_bytes, workspace),
       do: {:ok, %{paths: paths, staged: staged, context_lines: context, max_bytes: max_bytes}},
       else: {:error, Error.new(:coding_git_input_invalid)}
  end

  defp valid_context?(context), do: is_integer(context) and context >= 0 and context <= 20

  defp valid_max_bytes?(max_bytes, workspace),
    do: is_integer(max_bytes) and max_bytes > 0 and max_bytes <= workspace.limits.max_shell_output_bytes

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
