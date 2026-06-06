defmodule JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_tools_execute",
    description:
      "Executes a short sandboxed Lua script that returns jidoka.workflow({...}) over selected read-only host capabilities.",
    schema:
      Zoi.object(%{
        script: Zoi.string(),
        allowed_tools: Zoi.array(Zoi.string()) |> Zoi.default([]),
        max_calls: Zoi.integer() |> Zoi.default(12),
        max_parallel_calls: Zoi.integer() |> Zoi.default(8),
        timeout: Zoi.integer() |> Zoi.default(1_500)
      })

  alias JidokaExample.LuaToolsAgent.LuaRuntime

  @impl true
  def run(params, context) do
    script = params |> get(:script, "") |> to_string()
    allowed_tools = params |> get(:allowed_tools, []) |> List.wrap()
    max_calls = params |> get(:max_calls, 12) |> to_integer(12)
    max_parallel_calls = params |> get(:max_parallel_calls, 8) |> to_integer(8)
    timeout = params |> get(:timeout, 1_500) |> to_integer(1_500)

    case LuaRuntime.execute(script,
           allowed_tools: allowed_tools,
           context: context,
           max_calls: max_calls,
           max_parallel_calls: max_parallel_calls,
           timeout: timeout
         ) do
      {:ok, result} -> {:ok, result}
      {:error, %{} = result} -> {:ok, repairable_failure(result)}
      {:error, reason} -> {:ok, repairable_failure(failure_result(script, allowed_tools, reason))}
    end
  end

  defp failure_result(script, allowed_tools, reason) do
    %{
      "status" => "failed",
      "script" => script,
      "reason" => format_reason(reason),
      "calls" => [],
      "call_count" => 0,
      "allowed_tools" => Enum.map(allowed_tools, &to_string/1)
    }
  end

  defp repairable_failure(result) do
    Map.put_new(
      result,
      "next",
      "Fix the Lua script and call lua_tools_execute again. The script must start with return jidoka.workflow({...}); do not produce a final answer until status is completed."
    )
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))

  defp to_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp to_integer(_value, default), do: default

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
