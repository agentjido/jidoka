defmodule JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_tools_execute",
    description:
      "Executes a short sandboxed Lua script against selected read-only host capabilities.",
    schema:
      Zoi.object(%{
        script: Zoi.string(),
        allowed_tools: Zoi.array(Zoi.string()) |> Zoi.default([]),
        max_calls: Zoi.integer() |> Zoi.default(12)
      })

  alias JidokaExample.LuaToolsAgent.LuaRuntime

  @impl true
  def run(params, context) do
    script = params |> get(:script, "") |> to_string()
    allowed_tools = params |> get(:allowed_tools, []) |> List.wrap()
    max_calls = params |> get(:max_calls, 12) |> to_integer()

    case LuaRuntime.execute(script,
           allowed_tools: allowed_tools,
           context: context,
           max_calls: max_calls
         ) do
      {:ok, result} -> {:ok, result}
      {:error, %{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 12
    end
  end

  defp to_integer(_value), do: 12
end
