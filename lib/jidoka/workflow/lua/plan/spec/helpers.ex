defmodule Jidoka.Workflow.Lua.Plan.Spec.Helpers do
  @moduledoc false

  @spec known_value(map(), String.t(), term()) :: term()
  def known_value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_key_atom(key), default)
    end
  end

  @spec has_known_key?(map(), String.t()) :: boolean()
  def has_known_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, known_key_atom(key))

  @spec clamp_retries(term()) :: non_neg_integer()
  def clamp_retries(retries) when is_integer(retries), do: retries |> max(0) |> min(2)

  def clamp_retries(retries) when is_binary(retries) do
    case Integer.parse(retries) do
      {parsed, _rest} -> clamp_retries(parsed)
      :error -> 0
    end
  end

  def clamp_retries(_retries), do: 0

  @spec clamp_max_items(term()) :: pos_integer()
  def clamp_max_items(max_items) when is_integer(max_items), do: max_items |> max(1) |> min(25)

  def clamp_max_items(max_items) when is_binary(max_items) do
    case Integer.parse(max_items) do
      {parsed, _rest} -> clamp_max_items(parsed)
      :error -> 10
    end
  end

  def clamp_max_items(_max_items), do: 10

  @spec clamp_max_concurrency(term()) :: pos_integer()
  def clamp_max_concurrency(max_concurrency) when is_integer(max_concurrency) do
    max_concurrency |> max(1) |> min(16)
  end

  def clamp_max_concurrency(max_concurrency) when is_binary(max_concurrency) do
    case Integer.parse(max_concurrency) do
      {parsed, _rest} -> clamp_max_concurrency(parsed)
      :error -> 8
    end
  end

  def clamp_max_concurrency(_max_concurrency), do: 8

  defp known_key_atom("after"), do: :after
  defp known_key_atom("arguments"), do: :arguments
  defp known_key_atom("args"), do: :args
  defp known_key_atom("depends_on"), do: :depends_on
  defp known_key_atom("as"), do: :as
  defp known_key_atom("gate"), do: :gate
  defp known_key_atom("id"), do: :id
  defp known_key_atom("left"), do: :left
  defp known_key_atom("map"), do: :map
  defp known_key_atom("max_concurrency"), do: :max_concurrency
  defp known_key_atom("max_items"), do: :max_items
  defp known_key_atom("mode"), do: :mode
  defp known_key_atom("name"), do: :name
  defp known_key_atom("op"), do: :op
  defp known_key_atom("output"), do: :output
  defp known_key_atom("over"), do: :over
  defp known_key_atom("path"), do: :path
  defp known_key_atom("reduce"), do: :reduce
  defp known_key_atom("retries"), do: :retries
  defp known_key_atom("right"), do: :right
  defp known_key_atom("steps"), do: :steps
  defp known_key_atom("tool"), do: :tool
  defp known_key_atom("tool_id"), do: :tool_id
  defp known_key_atom("when"), do: :when
end
