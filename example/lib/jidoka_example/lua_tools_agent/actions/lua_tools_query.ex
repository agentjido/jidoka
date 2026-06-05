defmodule JidokaExample.LuaToolsAgent.Actions.LuaToolsQuery do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_tools_query",
    description: "Searches the hidden Lua tool catalog for relevant host capabilities.",
    schema:
      Zoi.object(%{
        query: Zoi.string(),
        limit: Zoi.integer() |> Zoi.default(5)
      })

  alias JidokaExample.LuaToolsAgent.Catalog

  @impl true
  def run(params, _context) do
    query = params |> get(:query, "") |> to_string()
    limit = params |> get(:limit, 5) |> to_limit()
    results = Catalog.query(query, limit: limit)

    {:ok,
     %{
       "query" => query,
       "count" => length(results),
       "tools" => results,
       "next" => "Call lua_tools_describe with the smallest useful set of tool ids."
     }}
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))

  defp to_limit(limit) when is_integer(limit), do: limit

  defp to_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> parsed
      :error -> 5
    end
  end

  defp to_limit(_limit), do: 5
end
