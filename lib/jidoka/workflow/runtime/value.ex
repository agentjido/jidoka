defmodule Jidoka.Workflow.Runtime.Value do
  @moduledoc false

  @spec resolve(term(), map()) :: {:ok, term()} | {:error, term()}
  def resolve({:jidoka_workflow_ref, :input, key}, state), do: fetch_equivalent(state.input, key, :input)
  def resolve({:jidoka_workflow_ref, :context, key}, state), do: fetch_equivalent(state.context, key, :context)
  def resolve({:jidoka_workflow_ref, :value, value}, _state), do: {:ok, value}
  def resolve({:jidoka_workflow_ref, :from, step, nil}, state), do: fetch_equivalent(state.steps, step, :step)

  def resolve({:jidoka_workflow_ref, :from, step, path}, state) when is_list(path) do
    with {:ok, value} <- fetch_equivalent(state.steps, step, :step) do
      resolve_path(value, path)
    end
  end

  def resolve(%{} = map, state) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve(value, state) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def resolve(list, state) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case resolve(value, state) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def resolve(tuple, state) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> resolve(state)
    |> case do
      {:ok, values} -> {:ok, List.to_tuple(values)}
      error -> error
    end
  end

  def resolve(value, _state), do: {:ok, value}

  @spec fetch_equivalent(map(), term()) :: {:ok, term()} | :error
  def fetch_equivalent(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        {:ok, Map.fetch!(map, Atom.to_string(key))}

      is_binary(key) ->
        case Enum.find(Map.keys(map), &(is_atom(&1) and Atom.to_string(&1) == key)) do
          nil -> :error
          existing -> {:ok, Map.fetch!(map, existing)}
        end

      true ->
        :error
    end
  end

  def fetch_equivalent(_map, _key), do: :error

  @spec fetch_equivalent(map(), term(), atom()) :: {:ok, term()} | {:error, term()}
  def fetch_equivalent(map, key, kind) do
    case fetch_equivalent(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_ref, kind, key}}
    end
  end

  @spec has_equivalent_key?(map(), term()) :: boolean()
  def has_equivalent_key?(map, key) when is_map(map), do: match?({:ok, _}, fetch_equivalent(map, key))
  def has_equivalent_key?(_map, _key), do: false

  defp resolve_path(value, []), do: {:ok, value}

  defp resolve_path(%{} = value, [key | rest]) do
    case fetch_equivalent(value, key) do
      {:ok, nested} -> resolve_path(nested, rest)
      :error -> {:error, {:missing_field, [key | rest], value}}
    end
  end

  defp resolve_path(value, path), do: {:error, {:missing_field, path, value}}
end
