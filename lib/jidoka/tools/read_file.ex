defmodule Jidoka.Tools.ReadFile do
  @moduledoc false

  use Jido.Action,
    name: "read_file",
    description: "Read a UTF-8 text file from the current workspace. This is a read-only tool.",
    category: "workspace",
    tags: ["workspace", "files", "read-only"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Workspace-relative path to a text file."
      ],
      max_bytes: [
        type: :integer,
        required: false,
        default: 65_536,
        doc: "Maximum bytes to return."
      ]
    ]

  alias Jidoka.Tools.{Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :read, fn ->
      workspace_path = Context.workspace_path(context)
      path = Map.get(params, :path) || Map.get(params, "path")
      max_bytes = Map.get(params, :max_bytes) || Map.get(params, "max_bytes") || 65_536

      with {:ok, file_path} <- Workspace.resolve_existing_path(workspace_path, path),
           {:ok, result} <- Workspace.read_text_file(file_path, max_bytes: max_bytes) do
        {:ok, Map.put(result, :workspace_path, workspace_path)}
      end
    end)
  end
end
