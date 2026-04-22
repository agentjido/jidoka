defmodule Jidoka.AI.Runtime do
  @moduledoc false

  @default_timeout_ms 120_000
  @default_openai_model "openai:gpt-4.1-mini"
  @default_anthropic_model "anthropic:claude-3-5-haiku-latest"

  @type runtime_options :: %{
          model: String.t(),
          timeout_ms: pos_integer()
        }

  @spec ensure_ready(keyword()) :: {:ok, runtime_options()} | {:error, String.t()}
  def ensure_ready(opts \\ []) do
    with {:ok, model} <- resolve_model(opts) do
      put_model_aliases(model)

      {:ok,
       %{
         model: model,
         timeout_ms: resolve_timeout_ms(opts)
       }}
    end
  end

  @spec resolve_timeout_ms(keyword()) :: pos_integer()
  def resolve_timeout_ms(opts \\ []) do
    case Keyword.get(opts, :timeout_ms) || System.get_env("JIDOKA_TIMEOUT_MS") do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      timeout when is_binary(timeout) ->
        case Integer.parse(timeout) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @default_timeout_ms
        end

      _ ->
        @default_timeout_ms
    end
  end

  @spec setup_instructions() :: String.t()
  def setup_instructions do
    """
    configure a model before running jidoka prompt.

    Supported setup paths:
      export JIDOKA_MODEL=\"openai:gpt-4.1-mini\"
      export OPENAI_API_KEY=\"...\"
      export ANTHROPIC_API_KEY=\"...\"
    """
    |> String.trim()
  end

  defp resolve_model(opts) do
    cond do
      model = Keyword.get(opts, :model) ->
        {:ok, model}

      model = System.get_env("JIDOKA_MODEL") ->
        {:ok, model}

      System.get_env("OPENAI_API_KEY") ->
        {:ok, @default_openai_model}

      System.get_env("ANTHROPIC_API_KEY") ->
        {:ok, @default_anthropic_model}

      true ->
        {:error, setup_instructions()}
    end
  end

  defp put_model_aliases(model) do
    aliases =
      Application.get_env(:jido_ai, :model_aliases, %{})
      |> Map.put(:fast, model)
      |> Map.put_new(:capable, model)

    Application.put_env(:jido_ai, :model_aliases, aliases)
  end
end
