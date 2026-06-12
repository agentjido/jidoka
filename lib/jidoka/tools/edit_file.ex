defmodule Jidoka.Tools.EditFile do
  @moduledoc false

  use Jido.Action,
    name: "edit_file",
    description: "Apply a bounded UTF-8 text replacement inside a workspace file.",
    category: "workspace",
    tags: ["workspace", "files", "write", "patch"],
    vsn: "1.0.0",
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "Workspace-relative file path to edit."
      ],
      search: [
        type: :string,
        required: true,
        doc: "Exact UTF-8 text to replace."
      ],
      replacement: [
        type: :string,
        required: true,
        doc: "Replacement UTF-8 text."
      ],
      expected_replacements: [
        type: :integer,
        required: false,
        default: 1,
        doc: "Exact number of replacements expected."
      ]
    ]

  alias Jidoka.Tools.{Context, ToolRuntime, Workspace}

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :write, fn ->
      workspace_path = Context.workspace_path(context)
      path = Map.get(params, :path) || Map.get(params, "path")
      search = Map.get(params, :search) || Map.get(params, "search")
      replacement = Map.get(params, :replacement) || Map.get(params, "replacement")

      expected =
        Map.get(params, :expected_replacements) || Map.get(params, "expected_replacements") || 1

      with :ok <- validate_patch(search, replacement, expected),
           {:ok, file_path} <- Workspace.resolve_write_path(workspace_path, path),
           {:ok, contents} <- read_editable_file(file_path),
           {:ok, updated_contents, replacement_count} <-
             apply_replacement(contents, search, replacement, expected),
           :ok <- File.write(file_path, updated_contents) do
        {:ok,
         %{
           workspace_path: workspace_path,
           path: Path.relative_to(file_path, workspace_path),
           replacements: replacement_count,
           bytes: byte_size(updated_contents)
         }}
      else
        {:error, reason} -> {:error, normalize_file_error(reason)}
      end
    end)
  end

  defp validate_patch(search, replacement, expected)
       when is_binary(search) and search != "" and is_binary(replacement) and is_integer(expected) and
              expected > 0 do
    if String.valid?(search) and String.valid?(replacement) do
      :ok
    else
      {:error, %{type: :binary_patch}}
    end
  end

  defp validate_patch(_search, _replacement, _expected), do: {:error, %{type: :invalid_patch}}

  defp read_editable_file(file_path) do
    case File.lstat(file_path) do
      {:ok, %{type: :regular}} ->
        case File.read(file_path) do
          {:ok, contents} ->
            if String.valid?(contents) do
              {:ok, contents}
            else
              {:error, %{type: :binary_file, path: file_path}}
            end

          {:error, reason} ->
            {:error, %{type: :file_read_failed, path: file_path, reason: reason}}
        end

      {:ok, %{type: :symlink}} ->
        {:error, %{type: :symlink_path, path: file_path}}

      {:ok, %{type: type}} ->
        {:error, %{type: :not_regular_file, path: file_path, file_type: type}}

      {:error, reason} ->
        {:error, %{type: :file_stat_failed, path: file_path, reason: reason}}
    end
  end

  defp apply_replacement(contents, search, replacement, expected) do
    count = replacement_count(contents, search)

    cond do
      count == 0 ->
        {:error, %{type: :patch_search_not_found}}

      count != expected ->
        {:error, %{type: :unexpected_replacement_count, expected: expected, actual: count}}

      true ->
        {:ok, String.replace(contents, search, replacement, global: true), count}
    end
  end

  defp replacement_count(contents, search) do
    contents
    |> String.split(search)
    |> length()
    |> Kernel.-(1)
  end

  defp normalize_file_error(reason) when is_map(reason), do: reason
  defp normalize_file_error(reason), do: %{type: :file_edit_failed, reason: reason}
end
