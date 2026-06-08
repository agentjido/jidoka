defmodule Jidoka.Workflow.Lua.Plan.Spec.Graph do
  @moduledoc false

  alias Jidoka.Workflow.Lua.Plan.Ref

  @spec validate_unique_step_ids([map()]) :: :ok | {:error, term()}
  def validate_unique_step_ids(steps) do
    ids = Enum.map(steps, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_lua_workflow_steps, Enum.uniq(duplicates)}}
    end
  end

  @spec validate_step_ids([map()]) :: :ok | {:error, term()}
  def validate_step_ids(steps) do
    invalid_ids =
      steps
      |> Enum.map(& &1.id)
      |> Enum.reject(&valid_step_id?/1)

    case invalid_ids do
      [] -> :ok
      invalid_ids -> {:error, {:invalid_lua_workflow_step_ids, invalid_ids}}
    end
  end

  @spec put_implicit_dependencies([map()]) :: [map()]
  def put_implicit_dependencies(steps) do
    Enum.map(steps, fn step ->
      refs = step_refs(step)
      Map.put(step, :after, Enum.uniq(step.explicit_after ++ refs))
    end)
  end

  @spec validate_dependencies([map()]) :: :ok | {:error, term()}
  def validate_dependencies(steps) do
    step_ids = steps |> Enum.map(& &1.id) |> MapSet.new()

    missing =
      steps
      |> Enum.flat_map(fn step ->
        step.after
        |> Enum.reject(&MapSet.member?(step_ids, &1))
        |> Enum.map(&{step.id, &1})
      end)

    self_dependencies =
      steps
      |> Enum.filter(fn step -> step.id in step.after end)
      |> Enum.map(& &1.id)

    cond do
      missing != [] -> {:error, {:missing_lua_workflow_dependencies, missing}}
      self_dependencies != [] -> {:error, {:self_referential_lua_workflow_steps, self_dependencies}}
      true -> :ok
    end
  end

  @spec validate_acyclic_dependencies([map()]) :: :ok | {:error, term()}
  def validate_acyclic_dependencies(steps) do
    graph = Map.new(steps, &{&1.id, &1.after})

    graph
    |> Map.keys()
    |> Enum.reduce_while({:ok, %{}}, fn step_id, {:ok, visited} ->
      case visit_step(step_id, graph, %{}, visited) do
        {:ok, visited} -> {:cont, {:ok, visited}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _visited} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp valid_step_id?(id), do: is_binary(id) and String.match?(id, ~r/^[a-z][a-z0-9_]*$/)

  defp step_refs(%{kind: :action} = step), do: Ref.collect(step.arguments) ++ Ref.collect(step.condition)

  defp step_refs(%{kind: :map, map: map} = step) do
    Ref.collect(map.over) ++ Ref.collect(map.arguments) ++ Ref.collect(step.condition)
  end

  defp step_refs(%{kind: :reduce, reduce: reduce} = step) do
    Ref.collect(reduce.over) ++ Ref.collect(step.condition)
  end

  defp step_refs(%{kind: :gate, gate: gate} = step) do
    Ref.collect(gate.left) ++ Ref.collect(gate.right) ++ Ref.collect(step.condition)
  end

  @spec visit_step(String.t(), %{String.t() => [String.t()]}, map(), map()) ::
          {:ok, map()} | {:error, term()}
  defp visit_step(step_id, graph, visiting, visited) do
    cond do
      Map.has_key?(visiting, step_id) ->
        {:error, {:cyclic_lua_workflow_dependency, step_id}}

      Map.has_key?(visited, step_id) ->
        {:ok, visited}

      true ->
        visit_new_step(step_id, graph, visiting, visited)
    end
  end

  defp visit_new_step(step_id, graph, visiting, visited) do
    visiting = Map.put(visiting, step_id, true)

    graph
    |> Map.get(step_id, [])
    |> visit_dependencies(graph, visiting, visited)
    |> mark_visited(step_id)
  end

  defp visit_dependencies(dependencies, graph, visiting, visited) do
    Enum.reduce_while(dependencies, {:ok, visited}, fn dependency, {:ok, visited} ->
      case visit_step(dependency, graph, visiting, visited) do
        {:ok, visited} -> {:cont, {:ok, visited}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp mark_visited({:ok, visited}, step_id), do: {:ok, Map.put(visited, step_id, true)}
  defp mark_visited({:error, _reason} = error, _step_id), do: error
end
