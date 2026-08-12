defmodule Jidoka.CodingPack.Glob do
  @moduledoc false

  alias Jidoka.CodingPack.Error

  @doc false
  @spec compile(String.t()) :: {:ok, Regex.t()} | {:error, Error.t()}
  def compile(pattern) when is_binary(pattern) do
    cond do
      pattern == "" ->
        {:error, Error.new(:coding_search_glob_invalid, %{reason: :empty})}

      not String.valid?(pattern) ->
        {:error, Error.new(:coding_search_glob_invalid, %{reason: :encoding})}

      Path.type(pattern) != :relative ->
        {:error, Error.new(:coding_search_glob_invalid, %{reason: :absolute})}

      Enum.any?(Path.split(pattern), &(&1 == "..")) ->
        {:error, Error.new(:coding_search_glob_invalid, %{reason: :parent_traversal})}

      String.contains?(pattern, ["[", "]", <<0>>]) ->
        {:error, Error.new(:coding_search_glob_invalid, %{reason: :unsupported_syntax})}

      true ->
        {:ok, Regex.compile!("^" <> expression(String.graphemes(normalize(pattern)), []) <> "$")}
    end
  end

  def compile(_pattern), do: {:error, Error.new(:coding_search_glob_invalid, %{reason: :type})}

  defp expression([], accumulator), do: accumulator |> Enum.reverse() |> Enum.join()

  defp expression(["*", "*", "/" | rest], accumulator),
    do: expression(rest, ["(?:.*/)?" | accumulator])

  defp expression(["*", "*" | rest], accumulator),
    do: expression(rest, [".*" | accumulator])

  defp expression(["*" | rest], accumulator),
    do: expression(rest, ["[^/]*" | accumulator])

  defp expression(["?" | rest], accumulator),
    do: expression(rest, ["[^/]" | accumulator])

  defp expression([character | rest], accumulator),
    do: expression(rest, [Regex.escape(character) | accumulator])

  defp normalize(pattern), do: String.replace(pattern, "\\", "/")
end
