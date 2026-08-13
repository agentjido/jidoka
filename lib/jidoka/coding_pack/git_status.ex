defmodule Jidoka.CodingPack.GitStatus do
  @moduledoc "Structured bounded Git status through a constrained environment."

  alias Jidoka.CodingPack.{Error, Git, GitPort, Workspace}

  @keys ~w(paths max_entries)

  @doc "Returns the model-visible Git status operation and handler."
  @spec tool(Workspace.t(), GitPort.t()) :: %{operation: Jidoka.Agent.Spec.Operation.t(), handler: function()}
  def tool(%Workspace{} = workspace, %GitPort{} = port) do
    %{
      operation:
        Jidoka.Agent.Spec.Operation.new!(
          name: "coding.git_status",
          description: "Return structured bounded Git working-tree status.",
          idempotency: :pure,
          metadata: %{
            "kind" => "tool",
            "source" => "coding_pack",
            "parameters_schema" => input_schema(workspace),
            "policy_resource" => %{
              "kind" => "coding_workspace",
              "access" => "git",
              "argument_fields" => ["paths", "max_entries"]
            }
          }
        ),
      handler: fn arguments, _context -> run(workspace, port, arguments) end
    }
  end

  defp input_schema(workspace) do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{"type" => "array", "items" => %{"type" => "string", "minLength" => 1}},
        "max_entries" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => workspace.limits.max_search_results
        }
      },
      "additionalProperties" => false
    }
  end

  @doc "Returns a deterministic structured status result."
  @spec run(Workspace.t(), GitPort.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace, port, arguments, opts \\ [])

  def run(%Workspace{} = workspace, %GitPort{} = port, arguments, opts)
      when is_map(arguments) and is_list(opts) do
    with true <- Workspace.permits?(workspace, :git),
         {:ok, input} <- input(arguments, workspace),
         {:ok, filters} <- Git.filters(workspace, input.paths),
         {:ok, shell} <-
           GitPort.run(
             port,
             workspace,
             ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--" | filters],
             Keyword.merge(opts, max_output_bytes: workspace.limits.max_shell_output_bytes)
           ) do
      result(shell, workspace, input.max_entries)
    else
      false -> {:error, Error.new(:coding_git_denied, %{reason: :workspace_access})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def run(%Workspace{}, %GitPort{}, _arguments, _opts), do: {:error, Error.new(:coding_git_input_invalid)}

  defp result(shell, workspace, max_entries) do
    case Git.command_outcome(shell) do
      {:ok, shell} ->
        {entries, invalid} = parse(shell["stdout"])
        {entries, omitted_ignored} = visible_entries(entries, workspace)
        entries = entries |> Enum.reverse() |> Enum.sort_by(& &1["path"])
        omitted_limit = max(length(entries) - max_entries, 0)
        entries = Enum.take(entries, max_entries)

        {:ok,
         shell
         |> Map.drop(["stdout", "stderr", "exit_status"])
         |> Map.merge(%{
           "status" => "ok",
           "clean" => entries == [] and omitted_ignored == 0 and omitted_limit == 0,
           "entries" => entries,
           "omitted_ignored" => omitted_ignored,
           "omitted_limit" => omitted_limit,
           "invalid_entries" => invalid,
           "truncated" => shell["stdout_truncated"] or omitted_limit > 0
         })}

      {:outcome, result} ->
        {:ok, Map.drop(result, ["stdout"])}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp parse(value), do: parse_tokens(Git.nul_paths(value), [], 0)

  defp visible_entries(entries, workspace) do
    Enum.reduce(entries, {[], 0}, fn entry, {visible, ignored} ->
      case Jidoka.CodingPack.Ignore.decision(workspace, entry["path"]) do
        {:ok, %{ignored?: false}} -> {[entry | visible], ignored}
        _other -> {visible, ignored + 1}
      end
    end)
  end

  defp parse_tokens([], entries, invalid), do: {Enum.reverse(entries), invalid}

  defp parse_tokens([token | rest], entries, invalid) when byte_size(token) >= 4 do
    <<index::binary-size(1), worktree::binary-size(1), " ", path::binary>> = token

    if index in ["R", "C"] or worktree in ["R", "C"] do
      case rest do
        [original | tail] -> parse_tokens(tail, [entry(index, worktree, path, original) | entries], invalid)
        [] -> parse_tokens([], entries, invalid + 1)
      end
    else
      parse_tokens(rest, [entry(index, worktree, path, nil) | entries], invalid)
    end
  end

  defp parse_tokens([_token | rest], entries, invalid), do: parse_tokens(rest, entries, invalid + 1)

  defp entry(index, worktree, path, original) do
    %{
      "path" => path,
      "original_path" => original,
      "index" => index,
      "worktree" => worktree,
      "kind" => kind(index, worktree),
      "staged" => index not in [" ", "?", "!"],
      "unstaged" => worktree not in [" ", "?", "!"],
      "untracked" => index == "?" and worktree == "?"
    }
  end

  defp kind("?", "?"), do: "untracked"
  defp kind("!", "!"), do: "ignored"
  defp kind(index, worktree) when index == "R" or worktree == "R", do: "renamed"
  defp kind(index, worktree) when index == "C" or worktree == "C", do: "copied"
  defp kind(index, worktree) when index == "A" or worktree == "A", do: "added"
  defp kind(index, worktree) when index == "D" or worktree == "D", do: "deleted"
  defp kind(index, worktree) when index == "U" or worktree == "U", do: "unmerged"
  defp kind(_index, _worktree), do: "modified"

  defp input(arguments, workspace) do
    arguments = stringify_keys(arguments)
    unknown = Map.keys(arguments) -- @keys
    paths = Map.get(arguments, "paths", [])
    max_entries = Map.get(arguments, "max_entries", workspace.limits.max_search_results)

    if unknown == [] and is_list(paths) and is_integer(max_entries) and max_entries > 0 and
         max_entries <= workspace.limits.max_search_results,
       do: {:ok, %{paths: paths, max_entries: max_entries}},
       else: {:error, Error.new(:coding_git_input_invalid)}
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
