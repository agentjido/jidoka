defmodule Jidoka.CodingPack.Instructions do
  @moduledoc "Bounded project-instruction discovery within a trusted workspace."

  alias Jidoka.CodingPack.{Error, Ignore, Workspace}

  @doc "Discovers instruction files from the workspace root to a selected directory."
  @spec discover(Workspace.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def discover(%Workspace{} = workspace, directory \\ ".") do
    case Workspace.resolve(workspace, directory, type: :directory) do
      {:ok, resolved} -> discover_resolved(workspace, resolved.relative)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp discover_resolved(workspace, relative) do
    candidates =
      for scope <- scopes(relative), filename <- workspace.instruction_files, do: join(scope, filename)

    Enum.reduce_while(candidates, {:ok, []}, &discovery_step(workspace, &1, &2))
  end

  defp discovery_step(workspace, path, {:ok, instructions}) do
    case instruction(workspace, path) do
      {:ok, nil} -> {:cont, {:ok, instructions}}
      {:ok, entry} -> add_entry(entry, instructions, workspace.limits)
      {:error, %Error{} = error} -> {:halt, {:error, error}}
    end
  end

  defp instruction(workspace, path) do
    case Workspace.resolve(workspace, path, type: :regular) do
      {:ok, resolved} ->
        with {:ok, %{ignored?: false}} <- Ignore.decision(workspace, resolved.relative),
             {:ok, stat} <- File.stat(resolved.absolute),
             :ok <- instruction_size(stat.size, workspace.limits.max_instruction_bytes, path),
             {:ok, contents} <- File.read(resolved.absolute),
             true <- String.valid?(contents) do
          {:ok,
           %{
             "path" => resolved.relative,
             "scope" => Path.dirname(resolved.relative) |> normalize_scope(),
             "bytes" => stat.size,
             "sha256" => digest(contents),
             "content" => contents
           }}
        else
          {:ok, %{ignored?: true}} -> {:ok, nil}
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, Error.new(:instruction_unavailable, %{path: path, reason: inspect(reason)})}
          false -> {:error, Error.new(:instruction_invalid_encoding, %{path: path})}
        end

      {:error, %Error{details: %{reason: reason}} = error} ->
        if String.contains?(reason, ":enoent"), do: {:ok, nil}, else: {:error, error}
    end
  end

  defp add_entry(entry, instructions, limits) do
    count = length(instructions) + 1
    total = Enum.reduce(instructions, entry["bytes"], &(&1["bytes"] + &2))

    cond do
      count > limits.max_instruction_files ->
        {:halt, {:error, Error.new(:instruction_file_limit_exceeded, %{limit: limits.max_instruction_files})}}

      total > limits.max_result_bytes ->
        {:halt, {:error, Error.new(:instruction_result_limit_exceeded, %{limit: limits.max_result_bytes})}}

      true ->
        {:cont, {:ok, instructions ++ [entry]}}
    end
  end

  defp instruction_size(size, limit, _path) when size <= limit, do: :ok

  defp instruction_size(size, limit, path),
    do: {:error, Error.new(:instruction_too_large, %{path: path, bytes: size, limit: limit})}

  defp scopes("."), do: ["."]

  defp scopes(relative) do
    Enum.reduce(Path.split(relative), ["."], fn part, acc ->
      acc ++ [join(List.last(acc), part)]
    end)
  end

  defp join(".", path), do: String.replace(path, "\\", "/")
  defp join(scope, path), do: Path.join(scope, path) |> String.replace("\\", "/")
  defp normalize_scope("."), do: "."
  defp normalize_scope(scope), do: String.replace(scope, "\\", "/")

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
