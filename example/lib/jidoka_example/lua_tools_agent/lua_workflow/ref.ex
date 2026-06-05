defmodule JidokaExample.LuaToolsAgent.LuaWorkflow.Ref do
  @moduledoc false

  @spec collect(term()) :: [String.t()]
  def collect(value), do: value |> do_collect([]) |> Enum.uniq()

  @spec resolve(term(), map()) :: {:ok, term()} | {:error, term()}
  def resolve(%{} = value, state) do
    case from(value) do
      nil ->
        value
        |> Enum.reduce_while({:ok, %{}}, fn {key, nested}, {:ok, acc} ->
          case resolve(nested, state) do
            {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      step_id ->
        resolve_ref(step_id, known_value(value, "path", []), state)
    end
  end

  def resolve(values, state) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case resolve(value, state) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def resolve(value, _state), do: {:ok, value}

  defp do_collect(%{} = value, refs) do
    case from(value) do
      nil -> Enum.reduce(Map.values(value), refs, &do_collect/2)
      step_id -> [step_id | refs]
    end
  end

  defp do_collect(values, refs) when is_list(values), do: Enum.reduce(values, refs, &do_collect/2)
  defp do_collect(_value, refs), do: refs

  defp resolve_ref(step_id, path, %{steps: steps}) do
    case Map.fetch(steps, step_id) do
      {:ok, output} -> resolve_path(output, normalize_path(path), step_id)
      :error -> {:error, {:missing_lua_workflow_ref, step_id}}
    end
  end

  defp resolve_path(value, [], _step_id), do: {:ok, value}

  defp resolve_path(value, [key | path], step_id) when is_map(value) do
    case fetch_path_key(value, key) do
      {:ok, nested} -> resolve_path(nested, path, step_id)
      :error -> {:error, {:missing_lua_workflow_path, step_id, key}}
    end
  end

  defp resolve_path(value, [key | path], step_id) when is_list(value) do
    with {:ok, index} <- path_index(key),
         {:ok, nested} <- fetch_list_index(value, index) do
      resolve_path(nested, path, step_id)
    else
      :error -> {:error, {:missing_lua_workflow_path, step_id, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_path(value, [key | _path], step_id),
    do: {:error, {:invalid_lua_workflow_path_target, step_id, key, value}}

  defp fetch_path_key(map, key) do
    key = to_string(key)

    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, known_path_atom(key))
    end
  end

  defp path_index(index) when is_integer(index) and index > 0, do: {:ok, index - 1}

  defp path_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed - 1}
      _other -> :error
    end
  end

  defp path_index(_index), do: :error

  defp fetch_list_index(values, index) do
    case Enum.fetch(values, index) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :error}
    end
  end

  defp normalize_path(nil), do: []
  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path) when is_binary(path), do: String.split(path, ".", trim: true)
  defp normalize_path(path), do: [path]

  defp from(value) when is_map(value) do
    case known_value(value, "from", nil) do
      from when is_binary(from) -> from
      from when is_atom(from) and not is_nil(from) -> Atom.to_string(from)
      _other -> nil
    end
  end

  defp from(_value), do: nil

  defp known_value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_key_atom(key), default)
    end
  end

  defp known_key_atom("from"), do: :from
  defp known_key_atom("path"), do: :path

  defp known_path_atom("customer_id"), do: :customer_id
  defp known_path_atom("id"), do: :id
  defp known_path_atom("name"), do: :name
  defp known_path_atom("company"), do: :company
  defp known_path_atom("count"), do: :count
  defp known_path_atom("total_due_cents"), do: :total_due_cents
  defp known_path_atom("customers"), do: :customers
  defp known_path_atom("invoices"), do: :invoices
  defp known_path_atom("note"), do: :note
  defp known_path_atom("output"), do: :output
  defp known_path_atom("steps"), do: :steps
  defp known_path_atom(key), do: key
end
