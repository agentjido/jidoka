defmodule Jidoka.CodingPack.Git do
  @moduledoc false

  alias Jidoka.CodingPack.{Error, Ignore, Workspace}

  @doc false
  @spec filters(Workspace.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, Error.t()}
  def filters(workspace, paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, filters} ->
      with true <- is_binary(path) and path != "",
           {:ok, resolved} <- Workspace.resolve(workspace, path, allow_missing: true),
           {:ok, %{ignored?: false}} <- Ignore.decision(workspace, resolved.relative) do
        {:cont, {:ok, [resolved.relative | filters]}}
      else
        false -> {:halt, {:error, Error.new(:coding_git_input_invalid)}}
        {:ok, decision} -> {:halt, {:error, Error.new(:coding_path_ignored, %{path: path, decision: decision})}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, filters} -> {:ok, filters |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def filters(_workspace, _paths), do: {:error, Error.new(:coding_git_input_invalid)}

  @doc false
  @spec visible_paths(Workspace.t(), [String.t()], pos_integer()) ::
          {[String.t()], non_neg_integer(), non_neg_integer()}
  def visible_paths(workspace, paths, limit) do
    paths
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({[], 0}, fn path, {visible, ignored} ->
      with {:ok, resolved} <- Workspace.resolve(workspace, path, allow_missing: true),
           {:ok, %{ignored?: false}} <- Ignore.decision(workspace, resolved.relative) do
        {[resolved.relative | visible], ignored}
      else
        _error -> {visible, ignored + 1}
      end
    end)
    |> then(fn {visible, ignored} ->
      visible = Enum.reverse(visible)
      {Enum.take(visible, limit), ignored, max(length(visible) - limit, 0)}
    end)
  end

  @doc false
  @spec command_outcome(map()) :: {:ok, map()} | {:outcome, map()} | {:error, Error.t()}
  def command_outcome(%{"status" => "nonzero", "stderr" => stderr} = result) do
    status =
      if String.contains?(String.downcase(stderr), "not a git repository"), do: "non_repository", else: "git_error"

    {:outcome, Map.put(result, "status", status)}
  end

  def command_outcome(%{"status" => status} = result) when status in ["timeout", "cancelled", "blocked", "error"],
    do: {:outcome, result}

  def command_outcome(%{"status" => "ok"} = result), do: {:ok, result}
  def command_outcome(_result), do: {:error, Error.new(:coding_git_result_invalid)}

  @doc false
  @spec nul_paths(String.t()) :: [String.t()]
  def nul_paths(value), do: value |> String.split(<<0>>, trim: true) |> Enum.reject(&(&1 == ""))
end
