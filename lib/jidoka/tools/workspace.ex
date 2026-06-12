defmodule Jidoka.Tools.Workspace do
  @moduledoc false

  @spec resolve_existing_path(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, map()}
  def resolve_existing_path(workspace_path, path) when is_binary(workspace_path) do
    with {:ok, workspace_realpath} <- realpath(workspace_path, :workspace),
         {:ok, expanded_path} <- expand_user_path(workspace_realpath, path),
         {:ok, target_realpath} <- realpath(expanded_path, :path),
         :ok <- ensure_within_workspace(workspace_realpath, target_realpath),
         :ok <- ensure_no_blocked_segments(workspace_realpath, target_realpath),
         :ok <- ensure_no_symlinks(workspace_realpath, target_realpath) do
      {:ok, target_realpath}
    end
  end

  @spec resolve_write_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def resolve_write_path(workspace_path, path)
      when is_binary(workspace_path) and is_binary(path) do
    with {:ok, workspace_realpath} <- realpath(workspace_path, :workspace),
         {:ok, expanded_path} <- expand_user_path(workspace_realpath, path),
         :ok <- ensure_file_target(workspace_realpath, expanded_path),
         :ok <- ensure_within_workspace(workspace_realpath, expanded_path),
         :ok <- ensure_no_blocked_segments(workspace_realpath, expanded_path),
         :ok <- ensure_no_symlinks_for_write(workspace_realpath, expanded_path) do
      {:ok, expanded_path}
    end
  end

  @spec list_files(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, map()}
  def list_files(root_path, opts \\ []) when is_binary(root_path) do
    limit = opts |> Keyword.get(:limit, 100) |> clamp_limit(1, 2_000)

    if File.dir?(root_path) do
      files =
        root_path
        |> stream_files()
        |> Enum.take(limit)
        |> Enum.map(&Path.relative_to(&1, root_path))
        |> Enum.sort()

      {:ok, files}
    else
      {:error, %{type: :not_directory, path: root_path}}
    end
  end

  @spec read_text_file(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def read_text_file(path, opts \\ []) when is_binary(path) do
    max_bytes = opts |> Keyword.get(:max_bytes, 65_536) |> clamp_limit(1, 262_144)

    with {:ok, stat} <- stat_regular_file(path),
         {:ok, contents} <- File.read(path),
         :ok <- ensure_text(contents) do
      truncated = byte_size(contents) > max_bytes
      text = binary_part(contents, 0, min(byte_size(contents), max_bytes))

      {:ok,
       %{
         path: path,
         bytes: stat.size,
         truncated: truncated,
         contents: text
       }}
    end
  end

  @spec clamp_limit(term(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp_limit(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  def clamp_limit(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> clamp_limit(parsed, min, max)
      _ -> min
    end
  end

  def clamp_limit(_value, min, _max), do: min

  defp stream_files(root_path) do
    Stream.resource(
      fn -> [root_path] end,
      fn
        [] ->
          {:halt, []}

        [path | rest] ->
          cond do
            file_type(path) == {:ok, :directory} ->
              children =
                case File.ls(path) do
                  {:ok, names} ->
                    names
                    |> Enum.reject(&ignored_path?/1)
                    |> Enum.map(&Path.join(path, &1))

                  {:error, _reason} ->
                    []
                end

              {[], children ++ rest}

            file_type(path) == {:ok, :regular} ->
              {[path], rest}

            true ->
              {[], rest}
          end
      end,
      fn _ -> :ok end
    )
  end

  defp ignored_path?(".git"), do: true
  defp ignored_path?(".jidoka"), do: true
  defp ignored_path?("_build"), do: true
  defp ignored_path?("deps"), do: true
  defp ignored_path?(_), do: false

  defp expand_user_path(workspace_realpath, nil), do: {:ok, workspace_realpath}
  defp expand_user_path(workspace_realpath, ""), do: {:ok, workspace_realpath}

  defp expand_user_path(workspace_realpath, path) when is_binary(path) do
    expanded =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, workspace_realpath)
      end

    {:ok, expanded}
  end

  defp realpath(path, label) do
    if File.exists?(path) do
      {:ok, Path.expand(path)}
    else
      {:error, %{type: :path_not_found, target: label, path: path, reason: :enoent}}
    end
  end

  defp ensure_within_workspace(workspace_realpath, target_realpath) do
    if target_realpath == workspace_realpath or
         String.starts_with?(target_realpath, workspace_realpath <> "/") do
      :ok
    else
      {:error,
       %{
         type: :path_outside_workspace,
         workspace_path: workspace_realpath,
         path: target_realpath
       }}
    end
  end

  defp ensure_file_target(workspace_realpath, target_path) do
    relative = Path.relative_to(target_path, workspace_realpath)

    cond do
      relative in ["", "."] ->
        {:error, %{type: :invalid_file_path, path: target_path}}

      String.ends_with?(target_path, "/") ->
        {:error, %{type: :invalid_file_path, path: target_path}}

      true ->
        :ok
    end
  end

  defp ensure_no_blocked_segments(workspace_realpath, target_realpath) do
    target_realpath
    |> Path.relative_to(workspace_realpath)
    |> Path.split()
    |> Enum.find(&ignored_path?/1)
    |> case do
      nil -> :ok
      segment -> {:error, %{type: :blocked_path, segment: segment, path: target_realpath}}
    end
  end

  defp ensure_no_symlinks(workspace_realpath, target_realpath) do
    target_realpath
    |> Path.relative_to(workspace_realpath)
    |> Path.split()
    |> Enum.reduce_while(workspace_realpath, fn part, current_path ->
      next_path = Path.join(current_path, part)

      case file_type(next_path) do
        {:ok, :symlink} ->
          {:halt, {:error, %{type: :symlink_path, path: next_path}}}

        {:ok, _type} ->
          {:cont, next_path}

        {:error, reason} ->
          {:halt, {:error, %{type: :path_not_found, path: next_path, reason: reason}}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_no_symlinks_for_write(workspace_realpath, target_path) do
    target_path
    |> Path.relative_to(workspace_realpath)
    |> Path.split()
    |> Enum.reduce_while(workspace_realpath, fn part, current_path ->
      next_path = Path.join(current_path, part)

      case file_type(next_path) do
        {:ok, :symlink} ->
          {:halt, {:error, %{type: :symlink_path, path: next_path}}}

        {:ok, :directory} ->
          {:cont, next_path}

        {:ok, :regular} ->
          if next_path == target_path do
            {:cont, next_path}
          else
            {:halt, {:error, %{type: :path_parent_not_directory, path: next_path}}}
          end

        {:ok, type} ->
          {:halt, {:error, %{type: :unsupported_file_type, path: next_path, file_type: type}}}

        {:error, :enoent} ->
          {:halt, next_path}

        {:error, reason} ->
          {:halt, {:error, %{type: :path_stat_failed, path: next_path, reason: reason}}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stat_regular_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: type}} -> {:error, %{type: :not_regular_file, path: path, file_type: type}}
      {:error, reason} -> {:error, %{type: :file_stat_failed, path: path, reason: reason}}
    end
  end

  defp ensure_text(contents) do
    if String.valid?(contents) do
      :ok
    else
      {:error, %{type: :binary_file}}
    end
  end

  defp file_type(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} -> {:ok, type}
      {:error, reason} -> {:error, reason}
    end
  end
end
