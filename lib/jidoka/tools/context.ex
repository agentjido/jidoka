defmodule Jidoka.Tools.Context do
  @moduledoc false

  alias Jidoka.AttemptExecution
  alias Jidoka.AttemptExecution.AttemptSpec

  @spec workspace_path(map()) :: String.t()
  def workspace_path(context) when is_map(context) do
    context
    |> fetch_any([:workspace_path, "workspace_path", :requested_cwd, "requested_cwd"])
    |> case do
      path when is_binary(path) and path != "" -> path
      _ -> File.cwd!()
    end
  end

  @spec permission_mode(map()) :: atom()
  def permission_mode(context) when is_map(context) do
    context
    |> fetch_any([:permission_mode, "permission_mode"])
    |> Jidoka.Tools.Permission.normalize_mode()
  end

  @spec attempt_spec(map()) :: AttemptSpec.t() | nil
  def attempt_spec(context) when is_map(context) do
    case fetch_any(context, [:jidoka_attempt_spec, "jidoka_attempt_spec"]) do
      %AttemptSpec{} = spec -> spec
      _ -> nil
    end
  end

  @spec report_progress(map(), atom(), String.t() | nil, map()) :: :ok | {:error, term()}
  def report_progress(context, label, message, metadata \\ %{})
      when is_map(context) and is_atom(label) and is_map(metadata) do
    case attempt_spec(context) do
      %AttemptSpec{} = spec -> AttemptExecution.report_progress(spec, label, message, metadata)
      nil -> :ok
    end
  end

  defp fetch_any(context, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(context, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end
end
