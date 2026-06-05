defmodule Jidoka.Workflow.Lua.Policy do
  @moduledoc false

  alias Jido.Action.Catalog
  alias Jido.Action.Catalog.Entry

  @default_timeout_ms 1_500
  @default_max_calls 12
  @default_max_parallel_calls 8
  @default_max_call_depth 64
  @default_max_script_bytes 6_000

  @enforce_keys [
    :allowed_tools,
    :entries,
    :max_calls,
    :max_parallel_calls,
    :max_call_depth,
    :max_script_bytes,
    :timeout_ms,
    :require_read_only?
  ]
  defstruct [
    :allowed_tools,
    :entries,
    :max_calls,
    :max_parallel_calls,
    :max_call_depth,
    :max_script_bytes,
    :timeout_ms,
    :require_read_only?
  ]

  @type t :: %__MODULE__{
          allowed_tools: [String.t()],
          entries: [Entry.t()],
          max_calls: pos_integer(),
          max_parallel_calls: pos_integer(),
          max_call_depth: pos_integer(),
          max_script_bytes: pos_integer(),
          timeout_ms: pos_integer(),
          require_read_only?: boolean()
        }

  @spec build(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(script, opts) when is_binary(script) and is_list(opts) do
    with {:ok, available_entries} <- available_entries(opts) do
      require_read_only? = Keyword.get(opts, :require_read_only?, true)
      default_ids = default_allowed_ids(available_entries, require_read_only?)
      allowed_tools = normalize_allowed_tools(Keyword.get(opts, :allowed_tools), default_ids)

      policy = %__MODULE__{
        allowed_tools: allowed_tools,
        entries: [],
        max_calls: opts |> Keyword.get(:max_calls, @default_max_calls) |> clamp_max_calls(),
        max_parallel_calls:
          opts
          |> Keyword.get(:max_parallel_calls, @default_max_parallel_calls)
          |> clamp_max_parallel_calls(),
        max_call_depth: opts |> Keyword.get(:max_call_depth, @default_max_call_depth) |> clamp_max_call_depth(),
        max_script_bytes: opts |> Keyword.get(:max_script_bytes, @default_max_script_bytes) |> clamp_max_script_bytes(),
        timeout_ms: opts |> Keyword.get(:timeout, @default_timeout_ms) |> clamp_timeout(),
        require_read_only?: require_read_only?
      }

      with :ok <- validate_script(script, policy),
           {:ok, entries} <- allowed_entries(available_entries, allowed_tools, policy) do
        {:ok, %{policy | entries: entries}}
      end
    end
  end

  @spec lua_options(t()) :: keyword()
  def lua_options(%__MODULE__{} = policy), do: [max_call_depth: policy.max_call_depth]

  @spec public(t()) :: map()
  def public(%__MODULE__{} = policy) do
    %{
      "mode" => if(policy.require_read_only?, do: "read_only", else: "configured"),
      "timeout_ms" => policy.timeout_ms,
      "max_calls" => policy.max_calls,
      "max_parallel_calls" => policy.max_parallel_calls,
      "max_call_depth" => policy.max_call_depth,
      "max_script_bytes" => policy.max_script_bytes,
      "sandbox" => "lua_default"
    }
  end

  defp available_entries(opts) do
    cond do
      Keyword.has_key?(opts, :entries) ->
        entries = opts |> Keyword.get(:entries) |> List.wrap()

        if Enum.all?(entries, &match?(%Entry{}, &1)) do
          {:ok, entries}
        else
          {:error, {:invalid_lua_workflow_entries, entries}}
        end

      Keyword.has_key?(opts, :catalog) ->
        case Keyword.fetch!(opts, :catalog) do
          %Catalog{} = catalog -> {:ok, Catalog.list(catalog)}
          catalog -> {:error, {:invalid_lua_workflow_catalog, catalog}}
        end

      true ->
        {:error, :missing_lua_workflow_catalog}
    end
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

  defp default_allowed_ids(entries, true) do
    entries
    |> Enum.filter(& &1.read_only?)
    |> Enum.map(& &1.id)
  end

  defp default_allowed_ids(entries, false), do: Enum.map(entries, & &1.id)

  defp allowed_entries(available_entries, allowed_tools, policy) do
    by_id = Map.new(available_entries, &{&1.id, &1})

    allowed_tools
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, entries} ->
      case Map.fetch(by_id, id) do
        {:ok, %{read_only?: true} = entry} ->
          {:cont, {:ok, entries ++ [entry]}}

        {:ok, %{read_only?: false} = entry} when policy.require_read_only? ->
          {:halt, {:error, {:lua_tool_not_read_only, entry.id}}}

        {:ok, entry} ->
          {:cont, {:ok, entries ++ [entry]}}

        :error ->
          {:halt, {:error, {:unknown_lua_tool, id}}}
      end
    end)
  end

  defp normalize_allowed_tools(nil, default_ids), do: default_ids
  defp normalize_allowed_tools([], default_ids), do: default_ids

  defp normalize_allowed_tools(values, _default_ids) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allowed_tools(value, default_ids), do: normalize_allowed_tools([value], default_ids)

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

  defp clamp_max_script_bytes(max_script_bytes) when is_integer(max_script_bytes) do
    max_script_bytes |> max(256) |> min(100_000)
  end

  defp clamp_max_script_bytes(_max_script_bytes), do: @default_max_script_bytes
end
