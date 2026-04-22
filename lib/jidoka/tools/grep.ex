defmodule Jidoka.Tools.Grep do
  @moduledoc false

  use Jido.Action,
    name: "grep",
    description: "Search UTF-8 text files in the current workspace. This is a read-only tool.",
    category: "workspace",
    tags: ["workspace", "search", "read-only"],
    vsn: "1.0.0",
    schema: [
      pattern: [
        type: :string,
        required: true,
        doc: "Literal text to search for."
      ],
      path: [
        type: :string,
        required: false,
        doc: "Optional workspace-relative directory or file to search."
      ],
      max_results: [
        type: :integer,
        required: false,
        default: 50,
        doc: "Maximum matching lines to return."
      ]
    ]

  alias Jidoka.Tools.{Context, ToolRuntime, Workspace}

  @max_file_bytes 1_048_576

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    ToolRuntime.run(context, __MODULE__, params, :read, fn ->
      workspace_path = Context.workspace_path(context)
      pattern = Map.get(params, :pattern) || Map.get(params, "pattern")
      path = Map.get(params, :path) || Map.get(params, "path")
      max_results = Map.get(params, :max_results) || Map.get(params, "max_results") || 50

      with {:ok, search_path} <- Workspace.resolve_existing_path(workspace_path, path),
           :ok <- validate_pattern(pattern),
           {:ok, matches} <- search(search_path, workspace_path, pattern, max_results) do
        {:ok,
         %{
           workspace_path: workspace_path,
           search_path: search_path,
           pattern: pattern,
           matches: matches,
           count: length(matches)
         }}
      end
    end)
  end

  defp validate_pattern(pattern) when is_binary(pattern) and pattern != "", do: :ok
  defp validate_pattern(_), do: {:error, %{type: :invalid_pattern}}

  defp search(path, workspace_path, pattern, max_results) do
    limit = Workspace.clamp_limit(max_results, 1, 500)

    files =
      cond do
        File.regular?(path) ->
          [path]

        File.dir?(path) ->
          case Workspace.list_files(path, limit: 2_000) do
            {:ok, relative_files} -> Enum.map(relative_files, &Path.join(path, &1))
            {:error, reason} -> throw({:search_error, reason})
          end

        true ->
          []
      end

    matches =
      files
      |> Enum.reduce_while([], fn file_path, acc ->
        file_path
        |> search_file(workspace_path, pattern)
        |> case do
          {:ok, file_matches} ->
            updated = acc ++ file_matches

            if length(updated) >= limit do
              {:halt, Enum.take(updated, limit)}
            else
              {:cont, updated}
            end

          {:error, _reason} ->
            {:cont, acc}
        end
      end)

    {:ok, matches}
  catch
    {:search_error, reason} -> {:error, reason}
  end

  defp search_file(file_path, workspace_path, pattern) do
    with {:ok, stat} <- File.stat(file_path),
         true <- stat.type == :regular,
         true <- stat.size <= @max_file_bytes,
         {:ok, contents} <- File.read(file_path),
         true <- String.valid?(contents) do
      matches =
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> String.contains?(line, pattern) end)
        |> Enum.map(fn {line, line_number} ->
          %{
            path: Path.relative_to(file_path, workspace_path),
            line: line_number,
            text: line
          }
        end)

      {:ok, matches}
    else
      _ -> {:error, :skipped}
    end
  end
end
