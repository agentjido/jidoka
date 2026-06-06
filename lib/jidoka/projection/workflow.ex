defmodule Jidoka.Projection.Workflow do
  @moduledoc false

  alias Jidoka.Projection.Value

  @spec target(term()) :: term()
  def target({module, function, arity})
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  def target(target) when is_atom(target), do: inspect(target)
  def target(target), do: Value.project(target)

  @spec ref(term()) :: term()
  def ref({:jidoka_workflow_ref, :input, key}), do: %{ref: :input, key: key}
  def ref({:jidoka_workflow_ref, :context, key}), do: %{ref: :context, key: key}
  def ref({:jidoka_workflow_ref, :value, value}), do: %{ref: :value, value: Value.project(value)}
  def ref({:jidoka_workflow_ref, :from, step, nil}), do: %{ref: :from, step: step}
  def ref({:jidoka_workflow_ref, :from, step, path}), do: %{ref: :from, step: step, path: path}
  def ref(%{} = map), do: Map.new(map, fn {key, value} -> {key, ref(value)} end)
  def ref(list) when is_list(list), do: Enum.map(list, &ref/1)
  def ref(nil), do: nil
  def ref(value), do: Value.project(value)
end
