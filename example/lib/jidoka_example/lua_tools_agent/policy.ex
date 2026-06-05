defmodule JidokaExample.LuaToolsAgent.Policy do
  @moduledoc false

  alias JidokaExample.LuaToolsAgent.Surface

  @default_timeout_ms 1_500
  @default_max_calls 12
  @default_max_parallel_calls 8
  @default_max_call_depth 64
  @max_script_bytes 6_000

  @enforce_keys [
    :allowed_tools,
    :entries,
    :max_calls,
    :max_parallel_calls,
    :max_call_depth,
    :max_script_bytes,
    :timeout_ms
  ]
  defstruct [
    :allowed_tools,
    :entries,
    :max_calls,
    :max_parallel_calls,
    :max_call_depth,
    :max_script_bytes,
    :timeout_ms
  ]

  @type t :: %__MODULE__{
          allowed_tools: [String.t()],
          entries: [Surface.entry()],
          max_calls: pos_integer(),
          max_parallel_calls: pos_integer(),
          max_call_depth: pos_integer(),
          max_script_bytes: pos_integer(),
          timeout_ms: pos_integer()
        }

  @spec build(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(script, opts) when is_binary(script) and is_list(opts) do
    allowed_tools = normalize_allowed_tools(Keyword.get(opts, :allowed_tools, Surface.ids()))

    policy = %__MODULE__{
      allowed_tools: allowed_tools,
      entries: [],
      max_calls: opts |> Keyword.get(:max_calls, @default_max_calls) |> clamp_max_calls(),
      max_parallel_calls:
        opts
        |> Keyword.get(:max_parallel_calls, @default_max_parallel_calls)
        |> clamp_max_parallel_calls(),
      max_call_depth: opts |> Keyword.get(:max_call_depth, @default_max_call_depth) |> clamp_max_call_depth(),
      max_script_bytes: @max_script_bytes,
      timeout_ms: opts |> Keyword.get(:timeout, @default_timeout_ms) |> clamp_timeout()
    }

    with :ok <- validate_script(script, policy),
         {:ok, entries} <- allowed_entries(allowed_tools) do
      {:ok, %{policy | entries: entries}}
    end
  end

  @spec lua_options(t()) :: keyword()
  def lua_options(%__MODULE__{} = policy), do: [max_call_depth: policy.max_call_depth]

  @spec public(t()) :: map()
  def public(%__MODULE__{} = policy) do
    %{
      "mode" => "read_only",
      "timeout_ms" => policy.timeout_ms,
      "max_calls" => policy.max_calls,
      "max_parallel_calls" => policy.max_parallel_calls,
      "max_call_depth" => policy.max_call_depth,
      "max_script_bytes" => policy.max_script_bytes,
      "sandbox" => "lua_default"
    }
  end

  defp validate_script(script, policy) do
    cond do
      String.trim(script) == "" ->
        {:error, :empty_lua_script}

      byte_size(script) > policy.max_script_bytes ->
        {:error, {:lua_script_too_large, byte_size(script), policy.max_script_bytes}}

      true ->
        :ok
    end
  end

  defp allowed_entries(allowed_tools) do
    allowed_tools
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, entries} ->
      case Surface.fetch(id) do
        {:ok, %{read_only?: true} = entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:ok, entry} -> {:halt, {:error, {:lua_tool_not_read_only, entry.id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_allowed_tools(nil), do: Surface.ids()
  defp normalize_allowed_tools([]), do: Surface.ids()

  defp normalize_allowed_tools(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allowed_tools(value), do: normalize_allowed_tools([value])

  defp clamp_timeout(timeout) when is_integer(timeout), do: timeout |> max(100) |> min(5_000)
  defp clamp_timeout(_timeout), do: @default_timeout_ms

  defp clamp_max_calls(max_calls) when is_integer(max_calls), do: max_calls |> max(1) |> min(25)
  defp clamp_max_calls(_max_calls), do: @default_max_calls

  defp clamp_max_parallel_calls(max_parallel_calls) when is_integer(max_parallel_calls) do
    max_parallel_calls |> max(1) |> min(16)
  end

  defp clamp_max_parallel_calls(_max_parallel_calls), do: @default_max_parallel_calls

  defp clamp_max_call_depth(max_call_depth) when is_integer(max_call_depth) do
    max_call_depth |> max(4) |> min(256)
  end

  defp clamp_max_call_depth(_max_call_depth), do: @default_max_call_depth
end
