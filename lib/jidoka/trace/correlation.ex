defmodule Jidoka.Trace.Correlation do
  @moduledoc false

  @doc false
  @spec refs(map() | keyword() | nil | term()) :: map()
  def refs(nil), do: %{}

  def refs(%{} = source) do
    source
    |> nested_refs()
    |> Map.merge(source |> extract_refs() |> drop_nil_values())
    |> drop_nil_values()
  end

  def refs(source) when is_list(source) do
    if Keyword.keyword?(source), do: source |> Map.new() |> refs(), else: %{}
  end

  def refs(_source), do: %{}

  defp nested_refs(%{} = source) do
    [:extra_refs, :refs, :context, :tool_context, :runtime_context, :metadata, :request_opts, :jido]
    |> Enum.reduce(%{}, fn key, acc ->
      case get_value(source, key) do
        %{} = nested -> Map.merge(acc, refs(nested))
        _ -> acc
      end
    end)
  end

  defp extract_refs(%{} = source) do
    %{
      session_id: get_value(source, :session_id) || get_value(source, :session),
      conversation_id:
        get_value(source, :conversation_id) ||
          get_value(source, Jidoka.Handoff.context_key()) ||
          get_value(source, :conversation),
      context_ref: get_value(source, :context_ref),
      request_id: get_value(source, :request_id),
      run_id: get_value(source, :run_id),
      trace_id: get_value(source, :trace_id) || get_value(source, :jido_trace_id),
      span_id: get_value(source, :span_id) || get_value(source, :jido_span_id),
      parent_span_id: get_value(source, :parent_span_id) || get_value(source, :jido_parent_span_id)
    }
  end

  defp get_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_value(map, key) when is_map(map), do: Map.get(map, key)
  defp get_value(_map, _key), do: nil

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
