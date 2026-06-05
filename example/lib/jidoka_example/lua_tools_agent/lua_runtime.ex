defmodule JidokaExample.LuaToolsAgent.LuaRuntime do
  @moduledoc false

  alias JidokaExample.LuaToolsAgent.CallTrace
  alias JidokaExample.LuaToolsAgent.Policy
  alias JidokaExample.LuaToolsAgent.Surface
  alias JidokaExample.LuaToolsAgent.ToolWorkflow

  @spec execute(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(script, opts \\ [])

  def execute(script, opts) when is_binary(script) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, policy} <- Policy.build(script, opts),
         {:ok, trace} <- CallTrace.start_link() do
      try do
        script
        |> run_with_timeout(policy, trace, context)
        |> result(script, policy, trace)
      after
        if Process.alive?(trace), do: Agent.stop(trace)
      end
    end
  end

  def execute(script, _opts), do: {:error, {:invalid_lua_script, script}}

  defp run_with_timeout(script, policy, trace, context) do
    task =
      Task.async(fn ->
        run_script(script, policy, trace, context)
      end)

    case Task.yield(task, policy.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, {:lua_timeout, policy.timeout_ms}}
    end
  end

  defp result({:ok, script_result}, script, policy, trace) do
    calls = CallTrace.calls(trace)

    {:ok,
     %{
       "status" => "completed",
       "script" => script,
       "result" => script_result,
       "calls" => calls,
       "call_count" => length(calls),
       "allowed_tools" => policy.allowed_tools,
       "policy" => Policy.public(policy)
     }}
  end

  defp result({:error, reason}, script, policy, trace) do
    calls = CallTrace.calls(trace)

    {:error,
     %{
       "status" => "failed",
       "script" => script,
       "reason" => format_reason(reason),
       "calls" => calls,
       "call_count" => length(calls),
       "allowed_tools" => policy.allowed_tools,
       "policy" => Policy.public(policy)
     }}
  end

  defp run_script(script, policy, trace, context) do
    lua =
      policy.entries
      |> Enum.reduce(new_lua(policy), fn entry, lua ->
        Lua.set!(lua, Surface.lua_path(entry), fn args, state ->
          call_entry(entry, args, state, trace, policy, context)
        end)
      end)
      |> Lua.set!(["jidoka", "parallel"], fn args, state ->
        call_parallel(args, state, trace, policy, context)
      end)

    case Lua.eval!(lua, script) do
      {[value], _lua} -> {:ok, normalize_lua_value(value)}
      {values, _lua} -> {:ok, Enum.map(values, &normalize_lua_value/1)}
    end
  rescue
    exception in [Lua.CompilerException, Lua.RuntimeException] ->
      {:error, Exception.message(exception)}

    exception ->
      {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp new_lua(policy), do: policy |> Policy.lua_options() |> Lua.new()

  defp call_entry(entry, args, state, trace, policy, context) do
    decoded_args =
      args
      |> decode_lua_args(state)
      |> case do
        [arg] -> normalize_lua_value(arg)
        [] -> %{}
        args -> %{"args" => Enum.map(args, &normalize_lua_value/1)}
      end
      |> ensure_map()

    case ToolWorkflow.run_call(entry.id, decoded_args, trace, policy, context) do
      {:ok, output} ->
        {encoded, state} = Lua.encode!(state, output)
        {[encoded], state}

      {:error, reason} ->
        {:error, format_reason(reason), state}
    end
  end

  defp call_parallel(args, state, trace, policy, context) do
    with {:ok, call_specs} <- normalize_parallel_args(args, state),
         {:ok, outputs} <- ToolWorkflow.run_calls(call_specs, trace, policy, context) do
      {encoded, state} = Lua.encode!(state, outputs)
      {[encoded], state}
    else
      {:error, reason} -> {:error, format_reason(reason), state}
    end
  end

  defp normalize_parallel_args(args, state) do
    args =
      args
      |> decode_lua_args(state)
      |> case do
        [arg] -> normalize_lua_value(arg)
        [] -> []
        args -> Enum.map(args, &normalize_lua_value/1)
      end

    args
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, calls} ->
      case normalize_parallel_call(call) do
        {:ok, call} -> {:cont, {:ok, calls ++ [call]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_parallel_call(%{} = call) do
    with {:ok, tool_id} <- parallel_tool_id(call),
         {:ok, arguments} <- parallel_arguments(call) do
      {:ok, %{tool_id: tool_id, arguments: arguments}}
    end
  end

  defp normalize_parallel_call(call), do: {:error, {:invalid_lua_parallel_call, call}}

  defp parallel_tool_id(call) do
    call
    |> first_present(["tool_id", "tool", "id", "name", "path"])
    |> case do
      nil -> {:error, {:missing_lua_parallel_tool, call}}
      path when is_list(path) -> {:ok, path |> Enum.map(&to_string/1) |> Enum.join(".")}
      tool_id -> {:ok, to_string(tool_id)}
    end
  end

  defp parallel_arguments(call) do
    arguments = first_present(call, ["arguments", "args", "input"]) || %{}
    {:ok, ensure_map(arguments)}
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      key
      |> fetch_known_key(map)
      |> case do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp fetch_known_key(key, map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, known_key_atom(key))
    end
  end

  defp known_key_atom("tool_id"), do: :tool_id
  defp known_key_atom("tool"), do: :tool
  defp known_key_atom("id"), do: :id
  defp known_key_atom("name"), do: :name
  defp known_key_atom("path"), do: :path
  defp known_key_atom("arguments"), do: :arguments
  defp known_key_atom("args"), do: :args
  defp known_key_atom("input"), do: :input

  defp decode_lua_args(args, state) when is_list(args), do: Lua.decode_list!(state, args)
  defp decode_lua_args(arg, state), do: [Lua.decode!(state, arg)]

  defp ensure_map(%{} = value), do: value
  defp ensure_map(value), do: %{"value" => value}

  defp normalize_lua_value(value) when is_list(value) do
    cond do
      keyword_pairs?(value) ->
        value
        |> Enum.map(fn {key, nested} -> {to_string(key), normalize_lua_value(nested)} end)
        |> Map.new()
        |> maybe_array_from_numeric_keys()

      true ->
        Enum.map(value, &normalize_lua_value/1)
    end
  end

  defp normalize_lua_value(value), do: value

  defp keyword_pairs?(value), do: Enum.all?(value, &match?({_key, _value}, &1))

  defp maybe_array_from_numeric_keys(map) do
    keys = Map.keys(map)

    if keys != [] and Enum.all?(keys, &numeric_string?/1) do
      map
      |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
      |> Enum.map(fn {_key, value} -> value end)
    else
      map
    end
  end

  defp numeric_string?(value) when is_binary(value), do: String.match?(value, ~r/^\d+$/)
  defp numeric_string?(_value), do: false

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
