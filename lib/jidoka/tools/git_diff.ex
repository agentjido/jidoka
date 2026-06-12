defmodule Jidoka.Tools.GitDiff do
  @moduledoc false

  use Jido.Action,
    name: "git_diff",
    description: "Return read-only git status, diff, or log output for the workspace.",
    category: "workspace",
    tags: ["workspace", "git", "read-only"],
    vsn: "1.0.0",
    schema: [
      mode: [
        type: :string,
        required: false,
        default: "diff",
        doc: "One of diff, status, or log."
      ],
      path: [
        type: :string,
        required: false,
        doc: "Optional workspace-relative path for diff."
      ],
      limit: [
        type: :integer,
        required: false,
        default: 20,
        doc: "Number of commits for log mode."
      ]
    ]

  alias Jidoka.Tools.{Command, Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :read, fn ->
      workspace_path = Context.workspace_path(context)
      mode = normalize_mode(Map.get(params, :mode) || Map.get(params, "mode") || "diff")
      path = Map.get(params, :path) || Map.get(params, "path")
      limit = Map.get(params, :limit) || Map.get(params, "limit") || 20

      with {:ok, args} <- args_for(mode, workspace_path, path, limit),
           {:ok, result} <- Command.run("git", args, cd: workspace_path, timeout_ms: 30_000) do
        {:ok, Map.merge(result, %{workspace_path: workspace_path, mode: mode})}
      end
    end)
  end

  defp normalize_mode("status"), do: :status
  defp normalize_mode(:status), do: :status
  defp normalize_mode("log"), do: :log
  defp normalize_mode(:log), do: :log
  defp normalize_mode(_), do: :diff

  defp args_for(:status, _workspace_path, _path, _limit),
    do: {:ok, ["status", "--short", "--branch"]}

  defp args_for(:log, _workspace_path, _path, limit) do
    {:ok, ["log", "--oneline", "-n", Integer.to_string(Workspace.clamp_limit(limit, 1, 100))]}
  end

  defp args_for(:diff, workspace_path, nil, _limit), do: args_for(:diff, workspace_path, "", nil)
  defp args_for(:diff, _workspace_path, "", _limit), do: {:ok, ["diff"]}

  defp args_for(:diff, workspace_path, path, _limit) do
    with {:ok, file_path} <- Workspace.resolve_existing_path(workspace_path, path) do
      {:ok, ["diff", "--", Path.relative_to(file_path, workspace_path)]}
    end
  end
end
