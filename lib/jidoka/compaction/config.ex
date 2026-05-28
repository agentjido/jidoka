defmodule Jidoka.Compaction.Config do
  @moduledoc false

  alias Jidoka.Compaction.Prompt

  @default_config %{
    mode: :auto,
    strategy: :summary,
    max_messages: 40,
    keep_last: 12,
    max_summary_chars: 4_000,
    prompt: nil
  }

  @doc false
  @spec default_config() :: Jidoka.Compaction.config()
  def default_config, do: @default_config

  @doc false
  @spec normalize_imported(nil | map()) :: {:ok, Jidoka.Compaction.config() | nil} | {:error, String.t()}
  def normalize_imported(nil), do: {:ok, nil}

  def normalize_imported(%{} = compaction) do
    attrs = %{
      mode: imported_atom(get_value(compaction, :mode, @default_config.mode)),
      strategy: imported_atom(get_value(compaction, :strategy, @default_config.strategy)),
      max_messages: get_value(compaction, :max_messages, @default_config.max_messages),
      keep_last: get_value(compaction, :keep_last, @default_config.keep_last),
      max_summary_chars: get_value(compaction, :max_summary_chars, @default_config.max_summary_chars),
      prompt: get_value(compaction, :prompt)
    }

    with {:ok, attrs} <- normalize_imported_prompt(attrs) do
      normalize_map(attrs)
    end
  end

  def normalize_imported(other),
    do: {:error, "compaction must be a map, got: #{inspect(other)}"}

  @doc false
  @spec externalize(Jidoka.Compaction.config() | nil) :: map() | nil
  def externalize(nil), do: nil

  def externalize(%{} = config) do
    %{
      "mode" => Atom.to_string(config.mode),
      "strategy" => Atom.to_string(config.strategy),
      "max_messages" => config.max_messages,
      "keep_last" => config.keep_last,
      "max_summary_chars" => config.max_summary_chars
    }
    |> maybe_put_prompt(config.prompt)
  end

  defp maybe_put_prompt(map, prompt) when is_binary(prompt), do: Map.put(map, "prompt", prompt)
  defp maybe_put_prompt(map, _prompt), do: map

  defp normalize_map(attrs) when is_map(attrs) do
    mode = Map.get(attrs, :mode, @default_config.mode)
    strategy = Map.get(attrs, :strategy, @default_config.strategy)
    max_messages = Map.get(attrs, :max_messages, @default_config.max_messages)
    keep_last = Map.get(attrs, :keep_last, @default_config.keep_last)
    max_summary_chars = Map.get(attrs, :max_summary_chars, @default_config.max_summary_chars)
    prompt = Map.get(attrs, :prompt, @default_config.prompt)

    with :ok <- validate_mode(mode),
         :ok <- validate_strategy(strategy),
         :ok <- validate_positive_integer(max_messages, :max_messages),
         :ok <- validate_positive_integer(keep_last, :keep_last),
         :ok <- validate_positive_integer(max_summary_chars, :max_summary_chars),
         :ok <- validate_keep_last(max_messages, keep_last) do
      {:ok,
       %{
         mode: mode,
         strategy: strategy,
         max_messages: max_messages,
         keep_last: keep_last,
         max_summary_chars: max_summary_chars,
         prompt: prompt
       }}
    end
  end

  defp validate_mode(mode) when mode in [:auto, :manual, :off], do: :ok

  defp validate_mode(other),
    do: {:error, "compaction mode must be :auto, :manual, or :off, got: #{inspect(other)}"}

  defp validate_strategy(:summary), do: :ok

  defp validate_strategy(other),
    do: {:error, "compaction strategy must be :summary, got: #{inspect(other)}"}

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(other, field),
    do: {:error, "compaction #{field} must be a positive integer, got: #{inspect(other)}"}

  defp validate_keep_last(max_messages, keep_last) when keep_last < max_messages, do: :ok

  defp validate_keep_last(max_messages, keep_last) do
    {:error, "compaction keep_last must be less than max_messages, got: #{keep_last} >= #{max_messages}"}
  end

  defp normalize_imported_prompt(%{prompt: nil} = attrs), do: {:ok, attrs}

  defp normalize_imported_prompt(%{prompt: prompt} = attrs) when is_binary(prompt) do
    with {:ok, normalized} <- Prompt.normalize(nil, prompt, label: "compaction prompt") do
      {:ok, Map.put(attrs, :prompt, normalized)}
    end
  end

  defp normalize_imported_prompt(%{prompt: prompt}) do
    {:error, "imported compaction prompt must be a string, got: #{inspect(prompt)}"}
  end

  defp imported_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      "auto" -> :auto
      "manual" -> :manual
      "off" -> :off
      "summary" -> :summary
      normalized -> normalized
    end
  end

  defp imported_atom(value), do: value

  defp get_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, normalize_lookup_key(key), default))
  end

  defp normalize_lookup_key(key) when is_atom(key), do: Atom.to_string(key)
end
