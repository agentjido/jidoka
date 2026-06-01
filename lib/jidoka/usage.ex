defmodule Jidoka.Usage do
  @moduledoc """
  Token and cost usage helpers for Jidoka turns.

  ReqLLM owns provider-specific extraction and cost calculation. Jidoka keeps a
  small, provider-neutral aggregate on `Jidoka.Turn.Result.usage` and leaves
  per-call details on each LLM effect result in the journal.
  """

  alias Jidoka.Effect

  @token_keys [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cached_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens,
    :cache_creation_tokens,
    :reasoning_tokens
  ]

  @cost_keys [
    :input_cost,
    :output_cost,
    :reasoning_cost,
    :total_cost
  ]

  @numeric_keys @token_keys ++ @cost_keys
  @string_key_aliases Map.new(@numeric_keys ++ [:input, :output], fn key ->
                        {Atom.to_string(key), key}
                      end)

  @doc """
  Normalizes a provider usage map into Jidoka's canonical usage keys.
  """
  @spec normalize(map() | nil | term()) :: map()
  def normalize(nil), do: %{}

  def normalize(usage) when is_map(usage) do
    usage
    |> normalize_key_names()
    |> normalize_token_aliases()
    |> Map.take(@numeric_keys)
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> Map.new()
  end

  def normalize(_usage), do: %{}

  @doc """
  Aggregates LLM usage from an effect journal.
  """
  @spec from_journal(Effect.Journal.t()) :: map()
  def from_journal(%Effect.Journal{} = journal) do
    calls =
      journal.results
      |> Map.values()
      |> Enum.filter(&llm_ok?/1)
      |> Enum.flat_map(&call_usage/1)

    case calls do
      [] ->
        %{}

      calls ->
        calls
        |> Enum.reduce(%{llm_calls: length(calls)}, fn %{usage: usage}, acc ->
          merge_usage(acc, usage)
        end)
        |> normalize_total_tokens()
    end
  end

  def from_journal(_journal), do: %{}

  defp llm_ok?(%Effect.Result{kind: :llm, status: :ok}), do: true
  defp llm_ok?(_result), do: false

  defp call_usage(%Effect.Result{} = result) do
    metadata = result.metadata || %{}

    usage =
      metadata
      |> get_key(:usage)
      |> normalize()

    if usage == %{} do
      []
    else
      [
        %{
          effect_id: result.intent_id,
          model: get_key(metadata, :model),
          finish_reason: get_key(metadata, :finish_reason),
          usage: usage
        }
      ]
    end
  end

  defp merge_usage(acc, usage) when is_map(usage) do
    Enum.reduce(@numeric_keys, acc, fn key, acc ->
      case Map.get(usage, key) do
        value when is_number(value) -> Map.update(acc, key, value, &(&1 + value))
        _other -> acc
      end
    end)
  end

  defp normalize_key_names(usage) do
    Map.new(usage, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_binary(key), do: Map.get(@string_key_aliases, key, key)

  defp normalize_key(key), do: key

  defp normalize_token_aliases(usage) do
    usage
    |> put_alias(:input_tokens, :input)
    |> put_alias(:output_tokens, :output)
    |> normalize_total_tokens()
  end

  defp put_alias(usage, canonical_key, alias_key) do
    case {Map.get(usage, canonical_key), Map.get(usage, alias_key)} do
      {nil, value} when is_number(value) -> Map.put(usage, canonical_key, value)
      _other -> usage
    end
  end

  defp normalize_total_tokens(%{total_tokens: total} = usage) when is_number(total), do: usage

  defp normalize_total_tokens(usage) do
    input = Map.get(usage, :input_tokens)
    output = Map.get(usage, :output_tokens)

    if is_number(input) and is_number(output) do
      Map.put(usage, :total_tokens, input + output)
    else
      usage
    end
  end

  defp get_key(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
