defmodule JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_tools_describe",
    description: "Returns exact Lua function specs for selected hidden host capabilities.",
    schema:
      Zoi.object(%{
        ids: Zoi.array(Zoi.string())
      })

  alias JidokaExample.LuaToolsAgent.Catalog

  @impl true
  def run(params, _context) do
    ids = params |> get(:ids, []) |> List.wrap() |> Enum.map(&to_string/1)

    with {:ok, tools} <- Catalog.describe(ids) do
      {:ok,
       %{
         "tools" => tools,
         "allowed_tools" => ids,
         "next" =>
           "Call lua_tools_execute with a short Lua script using only these Lua paths. Lua calls return their JSON maps directly; they are not wrapped in a result field."
       }}
    end
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
end
