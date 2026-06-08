defmodule Jidoka.Workflow.Lua do
  @moduledoc """
  Sandboxed Lua authoring layer for dynamic Jidoka workflow plans.

  Lua does not drive the core agent loop. It can author a bounded workflow plan
  by returning `jidoka.workflow({...})`; Jidoka validates that plan, executes
  allowed catalog actions through Runic, and returns structured results and call
  traces.
  """

  alias Jidoka.Workflow.Lua.CallTrace
  alias Jidoka.Workflow.Lua.Plan
  alias Jidoka.Workflow.Lua.Policy

  @doc """
  Executes a sandboxed Lua script with the `jidoka.workflow/1` host function.

  Required options:

  * `:catalog` - a `Jido.Action.Catalog` containing tools the Lua plan may use.
  * `:entries` - alternatively, a list of `Jido.Action.Catalog.Entry` structs.

  Common options:

  * `:allowed_tools` - selected catalog entry ids. Defaults to all provided entries.
  * `:context` - map passed to hidden actions.
  * `:timeout` - total Lua/workflow timeout in milliseconds.
  * `:max_calls` - maximum hidden action calls.
  * `:max_parallel_calls` - maximum concurrent hidden action calls.
  * `:require_read_only?` - defaults to `true`.
  """
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

  defp result({:ok, %{"workflow_id" => _workflow_id} = script_result}, script, policy, trace) do
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

  defp result({:ok, script_result}, script, policy, trace) do
    calls = CallTrace.calls(trace)

    {:error,
     %{
       "status" => "failed",
       "script" => script,
       "reason" => "Lua script must return jidoka.workflow({...}).",
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
      policy
      |> new_lua()
      |> Lua.set!(["jidoka", "workflow"], fn args, state ->
        call_workflow(args, state, trace, policy, context)
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

  defp call_workflow(args, state, trace, policy, context) do
    with {:ok, workflow_spec} <- normalize_workflow_args(args, state),
         {:ok, result} <- Plan.run(workflow_spec, trace, policy, context) do
      {encoded, state} = Lua.encode!(state, result)
      {[encoded], state}
    else
      {:error, reason} -> {:error, format_reason(reason), state}
    end
  end

  defp normalize_workflow_args(args, state) do
    args =
      args
      |> decode_lua_args(state)
      |> case do
        [arg] -> normalize_lua_value(arg)
        [] -> %{}
        args -> %{"args" => Enum.map(args, &normalize_lua_value/1)}
      end

    case args do
      %{} = workflow_spec -> {:ok, workflow_spec}
      workflow_spec -> {:error, {:invalid_lua_workflow, workflow_spec}}
    end
  end

  defp decode_lua_args(args, state) when is_list(args), do: Lua.decode_list!(state, args)
  defp decode_lua_args(arg, state), do: [Lua.decode!(state, arg)]

  defp normalize_lua_value(value) when is_list(value) do
    if keyword_pairs?(value) do
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), normalize_lua_value(nested)} end)
      |> Map.new()
      |> maybe_array_from_numeric_keys()
    else
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
