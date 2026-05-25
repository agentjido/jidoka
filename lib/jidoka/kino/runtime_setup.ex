defmodule Jidoka.Kino.RuntimeSetup do
  @moduledoc false

  alias Jidoka.Kino.Render

  require Logger

  @provider_env_names ["ANTHROPIC_API_KEY", "LB_ANTHROPIC_API_KEY"]
  @default_model_alias :fast
  @default_model "anthropic:claude-haiku-4-5"

  @spec provider_env_names() :: [String.t()]
  def provider_env_names, do: @provider_env_names

  @spec setup(keyword()) :: :ok
  def setup(opts \\ []) do
    configure_runtime(opts)
    _ = load_provider_env(Keyword.get(opts, :provider_env, @provider_env_names))

    :ok
  end

  @spec setup_notebook(keyword()) :: map()
  def setup_notebook(opts \\ []) do
    configure_runtime(opts)

    provider_env = Keyword.get(opts, :provider_env, @provider_env_names)
    provider = Keyword.get(opts, :provider, :anthropic)
    model_alias = Keyword.get(opts, :model_alias, @default_model_alias)
    model = Keyword.get(opts, :model, @default_model)
    source = Keyword.get(opts, :jidoka_source, :github)

    summary =
      case load_provider_env(provider_env) do
        {:ok, name} ->
          %{
            jidoka_source: source,
            model_alias: model_alias,
            model: model,
            provider: provider,
            live_provider?: true,
            secret_source: secret_source(name)
          }

        {:error, _message} ->
          %{
            jidoka_source: source,
            model_alias: model_alias,
            model: model,
            provider: provider,
            live_provider?: false,
            secret_source: nil
          }
      end

    if Keyword.get(opts, :render?, true), do: render_notebook_setup(summary)

    summary
  end

  @spec start_or_reuse(String.t(), (-> {:ok, pid()} | {:error, term()})) ::
          {:ok, pid()} | {:error, term()}
  def start_or_reuse(id, start_fun) when is_binary(id) and is_function(start_fun, 0) do
    case Jidoka.Runtime.whereis(id) do
      nil -> start_fun.()
      pid -> {:ok, pid}
    end
  end

  @spec load_provider_env([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def load_provider_env(names \\ @provider_env_names) when is_list(names) do
    case find_env(names) do
      nil ->
        clear_empty_env("ANTHROPIC_API_KEY")
        {:error, "Set ANTHROPIC_API_KEY, or a Livebook secret named ANTHROPIC_API_KEY"}

      {"ANTHROPIC_API_KEY", _key} ->
        {:ok, "ANTHROPIC_API_KEY"}

      {name, key} ->
        System.put_env("ANTHROPIC_API_KEY", key)
        {:ok, name}
    end
  end

  defp find_env(names) do
    Enum.find_value(names, fn name ->
      key = name |> System.get_env("") |> String.trim()

      case key do
        "" -> nil
        key -> {name, key}
      end
    end)
  end

  defp configure_runtime(opts) do
    show_raw_logs? = Keyword.get(opts, :show_raw_logs, false)
    log_level = if(show_raw_logs?, do: :notice, else: :warning)

    Logger.configure(level: log_level)
    Jidoka.Runtime.debug(if(show_raw_logs?, do: :on, else: :off))
  end

  defp render_notebook_setup(summary) do
    rows = [
      %{item: "Jidoka", status: source_label(summary.jidoka_source)},
      %{item: "Model", status: ":#{summary.model_alias} -> #{summary.model}"},
      %{item: "Anthropic", status: provider_status(summary)}
    ]

    Render.table("Setup", rows, keys: [:item, :status])
  end

  defp source_label(:github), do: "GitHub main"
  defp source_label(:hex), do: "Hex"
  defp source_label(source), do: inspect(source)

  defp provider_status(%{live_provider?: true, secret_source: :livebook_secret}), do: "ready from Livebook secret"
  defp provider_status(%{live_provider?: true, secret_source: :env}), do: "ready from environment"
  defp provider_status(%{live_provider?: true}), do: "ready"

  defp provider_status(%{provider: :anthropic}),
    do: "missing; enable a Livebook secret named ANTHROPIC_API_KEY"

  defp provider_status(%{provider: provider}), do: "missing #{provider} credentials"

  defp secret_source("ANTHROPIC_API_KEY"), do: :env
  defp secret_source("LB_" <> _name), do: :livebook_secret
  defp secret_source(_name), do: :env

  defp clear_empty_env(name) do
    if System.get_env(name) == "" do
      System.delete_env(name)
    end
  end
end
