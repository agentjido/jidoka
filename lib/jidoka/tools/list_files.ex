defmodule Jidoka.Tools.ListFiles do
  @moduledoc false

  use Jido.Action,
    name: "list_files",
    description: "List files under the current workspace. This is a read-only tool.",
    category: "workspace",
    tags: ["workspace", "files", "read-only"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: false,
        doc: "Optional workspace-relative directory to list. Defaults to the workspace root."
      ],
      limit: [
        type: :integer,
        required: false,
        default: 100,
        doc: "Maximum number of files to return."
      ]
    ]

  alias Jidoka.Tools.{Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :read, fn ->
      workspace_path = Context.workspace_path(context)
      path = Map.get(params, :path) || Map.get(params, "path")
      limit = Map.get(params, :limit) || Map.get(params, "limit") || 100

      with {:ok, root_path} <- Workspace.resolve_existing_path(workspace_path, path),
           {:ok, files} <- Workspace.list_files(root_path, limit: limit) do
        {:ok,
         %{
           workspace_path: workspace_path,
           root_path: root_path,
           files: files,
           count: length(files)
         }}
      end
    end)
  end
end
