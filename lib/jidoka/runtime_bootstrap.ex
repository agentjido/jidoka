defmodule Jidoka.RuntimeBootstrap do
  @moduledoc false

  @tzdata_dir_name "jidoka-tzdata"

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    with :ok <- prepare_tzdata(),
         :ok <- prepare_llm_db(),
         {:ok, _started} <- Application.ensure_all_started(:jidoka) do
      :ok
    end
  end

  @spec prepare_tzdata() :: :ok | {:error, term()}
  def prepare_tzdata do
    :ok = load_application(:tzdata)

    data_dir = Path.join(System.tmp_dir!(), @tzdata_dir_name)
    release_dir = Path.join(data_dir, "release_ets")

    File.mkdir_p!(release_dir)

    with :ok <- seed_tzdata_release_dir(release_dir) do
      Application.put_env(:tzdata, :autoupdate, :disabled)
      Application.put_env(:tzdata, :data_dir, data_dir)
      :ok
    end
  end

  defp seed_tzdata_release_dir(release_dir) do
    case Path.wildcard(Path.join(release_dir, "*.ets")) do
      [_ | _] ->
        :ok

      [] ->
        case locate_tzdata_release_dir() do
          {:ok, source_dir} ->
            source_dir
            |> Path.join("*.ets")
            |> Path.wildcard()
            |> Enum.each(fn source_file ->
              File.copy!(source_file, Path.join(release_dir, Path.basename(source_file)))
            end)

            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp locate_tzdata_release_dir do
    [
      Path.join([File.cwd!(), "deps", "tzdata", "priv", "release_ets"]),
      Path.join([
        Path.dirname(to_string(:escript.script_name())),
        "deps",
        "tzdata",
        "priv",
        "release_ets"
      ]),
      tzdata_app_release_dir()
    ]
    |> Enum.find(&valid_release_dir?/1)
    |> case do
      nil ->
        {:error, "could not locate tzdata release data for CLI startup"}

      path ->
        {:ok, path}
    end
  end

  defp tzdata_app_release_dir do
    try do
      Application.app_dir(:tzdata, "priv/release_ets")
    rescue
      _error -> nil
    end
  end

  defp valid_release_dir?(nil), do: false

  defp valid_release_dir?(path) do
    File.dir?(path) and Path.wildcard(Path.join(path, "*.ets")) != []
  end

  @spec prepare_llm_db() :: :ok | {:error, term()}
  def prepare_llm_db do
    :ok = load_application(:llm_db)

    case locate_llm_db_snapshot() do
      {:ok, snapshot_path} ->
        Application.put_env(:llm_db, :snapshot_path, snapshot_path)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp locate_llm_db_snapshot do
    [
      Path.join([File.cwd!(), "deps", "llm_db", "priv", "llm_db", "snapshot.json"]),
      Path.join([
        Path.dirname(to_string(:escript.script_name())),
        "deps",
        "llm_db",
        "priv",
        "llm_db",
        "snapshot.json"
      ]),
      llm_db_snapshot_path()
    ]
    |> Enum.find(&valid_snapshot_file?/1)
    |> case do
      nil ->
        {:error, "could not locate llm_db snapshot for CLI startup"}

      path ->
        {:ok, path}
    end
  end

  defp llm_db_snapshot_path do
    try do
      Application.app_dir(:llm_db, "priv/llm_db/snapshot.json")
    rescue
      _error -> nil
    end
  end

  defp valid_snapshot_file?(nil), do: false
  defp valid_snapshot_file?(path), do: File.regular?(path)

  defp load_application(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
    end
  end
end
