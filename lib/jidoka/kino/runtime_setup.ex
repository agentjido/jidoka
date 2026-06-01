defmodule Jidoka.Kino.RuntimeSetup do
  @moduledoc false

  alias Jidoka.Kino.Render

  @provider_env_names [
    "OPENAI_API_KEY",
    "LB_OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "LB_ANTHROPIC_API_KEY",
    "GEMINI_API_KEY",
    "LB_GEMINI_API_KEY"
  ]

  @provider_env %{
    openai: ["OPENAI_API_KEY", "LB_OPENAI_API_KEY"],
    anthropic: ["ANTHROPIC_API_KEY", "LB_ANTHROPIC_API_KEY"],
    gemini: ["GEMINI_API_KEY", "LB_GEMINI_API_KEY"],
    google: ["GEMINI_API_KEY", "LB_GEMINI_API_KEY"]
  }

  @spec provider_env_names() :: [String.t()]
  @doc false
  def provider_env_names, do: @provider_env_names

  @spec provider_env_names(atom() | String.t() | nil) :: [String.t()]
  @doc false
  def provider_env_names(nil), do: @provider_env_names

  def provider_env_names(provider) when is_atom(provider) do
    Map.get(@provider_env, provider, @provider_env_names)
  end

  def provider_env_names(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> provider_env_names()
  rescue
    ArgumentError -> @provider_env_names
  end

  @doc false
  @spec setup(keyword()) :: :ok
  def setup(opts \\ []) do
    if Keyword.get(opts, :load_provider_env?, true) do
      _ = load_provider_env(Keyword.get(opts, :provider_env, provider_env_names(Keyword.get(opts, :provider))))
    end

    :ok
  end

  @doc false
  @spec setup_notebook(keyword()) :: map()
  def setup_notebook(opts \\ []) do
    model = Keyword.get_lazy(opts, :model, fn -> Jidoka.Config.model_ref(Jidoka.Config.default_model()) end)
    provider = Keyword.get_lazy(opts, :provider, fn -> provider_from_model(model) end)
    provider_env = Keyword.get(opts, :provider_env, provider_env_names(provider))
    source = Keyword.get(opts, :jidoka_source, :path)
    check_provider? = Keyword.get(opts, :check_provider?, true)

    summary = notebook_summary(source, model, provider, provider_env, check_provider?)

    if Keyword.get(opts, :render?, true), do: render_notebook_setup(summary)

    summary
  end

  defp notebook_summary(source, model, provider, _provider_env, false) do
    %{
      jidoka_source: source,
      model: model,
      provider: provider,
      checked_provider?: false,
      live_provider?: false,
      secret_name: nil,
      secret_source: nil
    }
  end

  defp notebook_summary(source, model, provider, provider_env, true) do
    case load_provider_env(provider_env) do
      {:ok, name} ->
        %{
          jidoka_source: source,
          model: model,
          provider: provider,
          checked_provider?: true,
          live_provider?: true,
          secret_name: name,
          secret_source: secret_source(name)
        }

      {:error, _message} ->
        %{
          jidoka_source: source,
          model: model,
          provider: provider,
          checked_provider?: true,
          live_provider?: false,
          secret_name: nil,
          secret_source: nil
        }
    end
  end

  @doc false
  @spec start_or_reuse(String.t(), (-> DynamicSupervisor.on_start_child()), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_or_reuse(id, start_fun, opts \\ []) when is_binary(id) and is_function(start_fun, 0) do
    case Jidoka.whereis(id, opts) do
      nil -> start_fun.()
      pid -> {:ok, pid}
    end
  end

  @doc false
  @spec load_provider_env([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def load_provider_env(names \\ @provider_env_names) when is_list(names) do
    case find_env(names) do
      nil ->
        {:error, missing_provider_message(names)}

      {name, key} ->
        mirror_env(name, key)
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

  defp mirror_env("LB_" <> provider_name, key), do: System.put_env(provider_name, key)
  defp mirror_env(_name, _key), do: :ok

  defp missing_provider_message(names) do
    names
    |> Enum.reject(&String.starts_with?(&1, "LB_"))
    |> case do
      [] -> "Set a provider API key or matching Livebook secret"
      names -> "Set one of #{Enum.join(names, ", ")} or a matching Livebook secret"
    end
  end

  defp render_notebook_setup(summary) do
    rows = [
      %{item: "Jidoka", status: source_label(summary.jidoka_source)},
      %{item: "Model", status: summary.model},
      %{item: "Provider", status: provider_status(summary)}
    ]

    Render.table("Setup", rows, keys: [:item, :status])
  end

  defp provider_from_model(model) when is_binary(model) do
    model
    |> String.split(":", parts: 2)
    |> case do
      [provider, _id] when provider != "" -> provider
      _other -> nil
    end
  end

  defp provider_from_model(%LLMDB.Model{} = model), do: model.provider
  defp provider_from_model(_model), do: nil

  defp source_label(:path), do: "local path"
  defp source_label(:github), do: "GitHub"
  defp source_label(:hex), do: "Hex"
  defp source_label(source), do: inspect(source)

  defp provider_status(%{live_provider?: true, secret_source: :livebook_secret, secret_name: name}),
    do: "ready from Livebook secret #{name}"

  defp provider_status(%{live_provider?: true, secret_source: :env, secret_name: name}),
    do: "ready from environment #{name}"

  defp provider_status(%{live_provider?: true}), do: "ready"
  defp provider_status(%{checked_provider?: false}), do: "not required for deterministic notebook"
  defp provider_status(%{provider: nil}), do: "not checked"
  defp provider_status(%{provider: provider}), do: "missing #{provider} credentials"

  defp secret_source("LB_" <> _name), do: :livebook_secret
  defp secret_source(_name), do: :env
end
