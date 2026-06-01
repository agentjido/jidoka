defmodule Jidoka.Kino.ContextView do
  @moduledoc false

  alias Jidoka.Kino.Render

  @internal_atom_keys MapSet.new([
                        :agent_module,
                        :jido_agent,
                        :jidoka_spec,
                        :memory_store,
                        :domain,
                        :mcp_client,
                        :parent_context
                      ])

  @doc false
  @spec context(String.t(), map(), keyword()) :: :ok
  def context(label, context, opts \\ []) when is_binary(label) and is_map(context) do
    context
    |> Enum.map(fn {key, value} ->
      %{
        visibility: context_visibility(key),
        key: format_context_key(key),
        type: value_type(value),
        preview: Render.inspect_value(value, Keyword.get(opts, :limit, 25))
      }
    end)
    |> Enum.sort_by(fn row -> {visibility_order(row.visibility), row.key} end)
    |> then(&Render.table(label, &1, keys: [:visibility, :key, :type, :preview]))
  end

  defp context_visibility(key) do
    if internal_context_key?(key), do: "internal", else: "public"
  end

  defp visibility_order("public"), do: 0
  defp visibility_order("internal"), do: 1
  defp visibility_order(_visibility), do: 2

  defp internal_context_key?(key) when is_atom(key) do
    MapSet.member?(@internal_atom_keys, key) or key |> Atom.to_string() |> internal_context_key?()
  end

  defp internal_context_key?(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.starts_with?("__")
  end

  defp internal_context_key?(_key), do: false

  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_float(value), do: "float"
  defp value_type(value) when is_boolean(value), do: "boolean"
  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_pid(value), do: "pid"
  defp value_type(_value), do: "term"

  defp format_context_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_context_key(key) when is_binary(key), do: key
  defp format_context_key(key), do: inspect(key)
end
