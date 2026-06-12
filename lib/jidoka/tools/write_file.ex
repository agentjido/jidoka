defmodule Jidoka.Tools.WriteFile do
  @moduledoc false

  use Jido.Action,
    name: "write_file",
    description: "Create or overwrite a UTF-8 text file inside the workspace.",
    category: "workspace",
    tags: ["workspace", "files", "write"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Workspace-relative file path to write."
      ],
      contents: [
        type: :string,
        required: true,
        doc: "UTF-8 text contents to write."
      ],
      overwrite: [
        type: :boolean,
        required: false,
        default: true,
        doc: "Whether an existing file may be overwritten."
      ]
    ]

  alias Jidoka.Tools.{Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :write, fn ->
      workspace_path = Context.workspace_path(context)
      path = Map.get(params, :path) || Map.get(params, "path")
      contents = Map.get(params, :contents) || Map.get(params, "contents")
      overwrite? = Map.get(params, :overwrite, Map.get(params, "overwrite", true))

      with :ok <- validate_contents(contents),
           {:ok, file_path} <- Workspace.resolve_write_path(workspace_path, path),
           :ok <- validate_existing_target(file_path, overwrite?),
           existed? <- File.exists?(file_path),
           :ok <- File.mkdir_p(Path.dirname(file_path)),
           :ok <- File.write(file_path, contents) do
        {:ok,
         %{
           workspace_path: workspace_path,
           path: Path.relative_to(file_path, workspace_path),
           bytes: byte_size(contents),
           overwritten: existed? and overwrite?
         }}
      else
        {:error, reason} -> {:error, normalize_file_error(reason)}
      end
    end)
  end

  defp validate_contents(contents) when is_binary(contents) do
    if String.valid?(contents), do: :ok, else: {:error, %{type: :binary_contents}}
  end

  defp validate_contents(_), do: {:error, %{type: :invalid_contents}}

  defp validate_existing_target(file_path, overwrite?) do
    case File.lstat(file_path) do
      {:ok, %{type: :regular}} ->
        with :ok <- ensure_overwrite_allowed(overwrite?) do
          validate_existing_text_file(file_path)
        end

      {:ok, %{type: :symlink}} ->
        {:error, %{type: :symlink_path, path: file_path}}

      {:ok, %{type: type}} ->
        {:error, %{type: :not_regular_file, path: file_path, file_type: type}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, %{type: :file_stat_failed, path: file_path, reason: reason}}
    end
  end

  defp ensure_overwrite_allowed(true), do: :ok
  defp ensure_overwrite_allowed(_), do: {:error, %{type: :file_exists}}

  defp validate_existing_text_file(file_path) do
    case File.read(file_path) do
      {:ok, contents} ->
        if String.valid?(contents) do
          :ok
        else
          {:error, %{type: :binary_file, path: file_path}}
        end

      {:error, reason} ->
        {:error, %{type: :file_read_failed, path: file_path, reason: reason}}
    end
  end

  defp normalize_file_error(reason) when is_map(reason), do: reason
  defp normalize_file_error(reason), do: %{type: :file_write_failed, reason: reason}
end
