defmodule Jidoka.Workflow.Definition.Graph do
  @moduledoc false

  alias Jidoka.Workflow.Definition.Refs
  alias Jidoka.Workflow.Step

  @spec infer_dependencies([Step.t()]) :: %{required(atom()) => [atom()]}
  def infer_dependencies(steps) do
    Map.new(steps, fn step ->
      dependencies =
        step
        |> step_ref_terms()
        |> Refs.collect()
        |> Map.fetch!(:from)
        |> Enum.concat(step.after)
        |> Enum.uniq()

      {step.name, dependencies}
    end)
  end

  @spec sort_steps([Step.t()], map()) :: {:ok, [Step.t()]} | {:error, [atom()]}
  def sort_steps(steps, dependencies) do
    order = Enum.map(steps, & &1.name)
    by_name = Map.new(steps, &{&1.name, &1})

    case topo_sort(dependencies, order, []) do
      {:ok, sorted_names} -> {:ok, Enum.map(sorted_names, &Map.fetch!(by_name, &1))}
      {:error, cyclic_names} -> {:error, cyclic_names}
    end
  end

  defp step_ref_terms(%Step{kind: :action} = step), do: condition_ref_terms(step) ++ [step.input]
  defp step_ref_terms(%Step{kind: :function} = step), do: condition_ref_terms(step) ++ [step.input]
  defp step_ref_terms(%Step{kind: :agent} = step), do: condition_ref_terms(step) ++ [step.prompt, step.context]
  defp step_ref_terms(%Step{kind: :gate} = step), do: [step.condition]
  defp step_ref_terms(%Step{kind: :map} = step), do: condition_ref_terms(step) ++ [step.over, step.input]
  defp step_ref_terms(%Step{kind: :reduce} = step), do: condition_ref_terms(step) ++ [step.over, step.input]

  defp condition_ref_terms(%Step{} = step), do: [step.condition_when, step.condition_unless]

  defp topo_sort(dependencies, _order, acc) when map_size(dependencies) == 0 do
    {:ok, Enum.reverse(acc)}
  end

  defp topo_sort(dependencies, order, acc) do
    ready =
      order
      |> Enum.filter(fn name -> Map.get(dependencies, name) == [] end)

    case ready do
      [] ->
        {:error, Map.keys(dependencies)}

      _ ->
        ready_set = MapSet.new(ready)

        dependencies =
          dependencies
          |> Map.drop(ready)
          |> Map.new(fn {name, deps} ->
            {name, Enum.reject(deps, &MapSet.member?(ready_set, &1))}
          end)

        topo_sort(dependencies, Enum.reject(order, &MapSet.member?(ready_set, &1)), Enum.reverse(ready) ++ acc)
    end
  end
end
