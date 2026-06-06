defmodule Jidoka.Workflow.Definition.Refs do
  @moduledoc false

  @type refs :: %{input: [term()], from: [term()], context: [term()]}

  @spec collect(term()) :: refs()
  def collect(term) do
    term
    |> collect(%{input: [], from: [], context: []})
    |> normalize()
  end

  defp collect({:jidoka_workflow_ref, :input, key}, acc),
    do: Map.update!(acc, :input, &[key | &1])

  defp collect({:jidoka_workflow_ref, :from, step, _path}, acc),
    do: Map.update!(acc, :from, &[step | &1])

  defp collect({:jidoka_workflow_ref, :maybe_from, step, _path}, acc),
    do: Map.update!(acc, :from, &[step | &1])

  defp collect({:jidoka_workflow_ref, :context, key}, acc),
    do: Map.update!(acc, :context, &[key | &1])

  defp collect({:jidoka_workflow_ref, :value, _value}, acc), do: acc
  defp collect({:jidoka_workflow_ref, :coalesce, values}, acc), do: collect(values, acc)
  defp collect({:jidoka_workflow_ref, kind}, acc) when kind in [:item, :index, :items], do: acc
  defp collect(%{} = map, acc), do: Enum.reduce(Map.values(map), acc, &collect/2)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)

  defp collect(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect/2)
  end

  defp collect(_other, acc), do: acc

  defp normalize(acc) do
    %{
      input: Enum.uniq(acc.input),
      from: Enum.uniq(acc.from),
      context: Enum.uniq(acc.context)
    }
  end

  @spec special_kinds(term()) :: [atom()]
  def special_kinds(term) do
    term
    |> collect_special(MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_special({:jidoka_workflow_ref, kind}, acc) when kind in [:item, :index, :items] do
    MapSet.put(acc, kind)
  end

  defp collect_special({:jidoka_workflow_ref, :coalesce, values}, acc), do: collect_special(values, acc)
  defp collect_special({:jidoka_workflow_ref, _kind, _key}, acc), do: acc
  defp collect_special({:jidoka_workflow_ref, _kind, _step, _path}, acc), do: acc
  defp collect_special(%{} = map, acc), do: Enum.reduce(Map.values(map), acc, &collect_special/2)
  defp collect_special(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_special/2)

  defp collect_special(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_special/2)
  end

  defp collect_special(_other, acc), do: acc
end
