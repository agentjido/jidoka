defmodule JidokaExample.LuaToolsAgent.LuaWorkflow.Spec do
  @moduledoc false

  alias Jido.Action.Catalog.Entry
  alias JidokaExample.LuaToolsAgent.LuaWorkflow.Ref
  alias JidokaExample.LuaToolsAgent.Policy

  @enforce_keys [:id, :steps, :output]
  defstruct [:id, :steps, :output]

  @type step :: %{
          required(:id) => String.t(),
          required(:entry) => Entry.t(),
          required(:arguments) => map(),
          required(:after) => [String.t()],
          required(:retries) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          steps: [step()],
          output: term()
        }

  @spec new(map(), Policy.t()) :: {:ok, t()} | {:error, term()}
  def new(raw_spec, %Policy{} = policy) when is_map(raw_spec) do
    allowed = Map.new(policy.entries, &{&1.id, &1})
    workflow_retries = raw_spec |> known_value("retries", 0) |> clamp_retries()
    id = raw_spec |> known_value("id", "lua_workflow") |> to_string()

    with {:ok, raw_steps} <- fetch_steps(raw_spec),
         {:ok, steps} <- normalize_steps(raw_steps, allowed, workflow_retries),
         :ok <- validate_unique_step_ids(steps),
         :ok <- validate_step_ids(steps),
         steps = put_implicit_dependencies(steps),
         :ok <- validate_dependencies(steps),
         :ok <- validate_acyclic_dependencies(steps),
         {:ok, output} <- normalize_output(known_value(raw_spec, "output", nil), steps),
         :ok <- validate_output_refs(output, steps) do
      {:ok, %__MODULE__{id: id, steps: steps, output: output}}
    end
  end

  def new(raw_spec, %Policy{}), do: {:error, {:invalid_lua_workflow, raw_spec}}

  defp fetch_steps(raw_spec) do
    case known_value(raw_spec, "steps", nil) do
      steps when is_list(steps) and steps != [] -> {:ok, steps}
      steps -> {:error, {:invalid_lua_workflow_steps, steps}}
    end
  end

  defp normalize_steps(raw_steps, allowed, workflow_retries) do
    raw_steps
    |> Enum.reduce_while({:ok, []}, fn raw_step, {:ok, steps} ->
      case normalize_step(raw_step, allowed, workflow_retries) do
        {:ok, step} -> {:cont, {:ok, steps ++ [step]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_step(raw_step, allowed, workflow_retries) when is_map(raw_step) do
    with {:ok, id} <- fetch_step_id(raw_step),
         {:ok, tool_id} <- fetch_step_tool(raw_step),
         {:ok, entry} <- fetch_allowed_entry(allowed, tool_id),
         {:ok, arguments} <- fetch_step_arguments(raw_step),
         {:ok, explicit_after} <- fetch_step_after(raw_step) do
      retries =
        raw_step
        |> known_value("retries", workflow_retries)
        |> clamp_retries()

      {:ok,
       %{
         id: id,
         entry: entry,
         arguments: arguments,
         explicit_after: explicit_after,
         after: explicit_after,
         retries: retries
       }}
    end
  end

  defp normalize_step(raw_step, _allowed, _workflow_retries),
    do: {:error, {:invalid_lua_workflow_step, raw_step}}

  defp fetch_step_id(raw_step) do
    case known_value(raw_step, "id", known_value(raw_step, "name", nil)) do
      id when is_binary(id) -> {:ok, id}
      id when is_atom(id) and not is_nil(id) -> {:ok, Atom.to_string(id)}
      id -> {:error, {:invalid_lua_workflow_step_id, id}}
    end
  end

  defp fetch_step_tool(raw_step) do
    case known_value(raw_step, "tool", known_value(raw_step, "tool_id", nil)) do
      tool_id when is_binary(tool_id) -> {:ok, tool_id}
      path when is_list(path) -> {:ok, Enum.map_join(path, ".", &to_string/1)}
      tool_id -> {:error, {:invalid_lua_workflow_step_tool, tool_id}}
    end
  end

  defp fetch_allowed_entry(allowed, tool_id) do
    case Map.fetch(allowed, tool_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:lua_tool_not_allowed, tool_id}}
    end
  end

  defp fetch_step_arguments(raw_step) do
    case known_value(raw_step, "arguments", known_value(raw_step, "args", %{})) do
      nil -> {:ok, %{}}
      arguments when is_map(arguments) -> {:ok, arguments}
      arguments -> {:error, {:invalid_lua_workflow_step_arguments, arguments}}
    end
  end

  defp fetch_step_after(raw_step) do
    case known_value(raw_step, "after", known_value(raw_step, "depends_on", [])) do
      nil -> {:ok, []}
      dependencies when is_list(dependencies) -> {:ok, Enum.map(dependencies, &to_string/1)}
      dependency -> {:ok, [to_string(dependency)]}
    end
  end

  defp validate_unique_step_ids(steps) do
    ids = Enum.map(steps, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      duplicates -> {:error, {:duplicate_lua_workflow_steps, Enum.uniq(duplicates)}}
    end
  end

  defp validate_step_ids(steps) do
    invalid_ids =
      steps
      |> Enum.map(& &1.id)
      |> Enum.reject(&valid_step_id?/1)

    case invalid_ids do
      [] -> :ok
      invalid_ids -> {:error, {:invalid_lua_workflow_step_ids, invalid_ids}}
    end
  end

  defp valid_step_id?(id), do: is_binary(id) and String.match?(id, ~r/^[a-z][a-z0-9_]*$/)

  defp put_implicit_dependencies(steps) do
    Enum.map(steps, fn step ->
      refs = Ref.collect(step.arguments)
      Map.put(step, :after, Enum.uniq(step.explicit_after ++ refs))
    end)
  end

  defp validate_dependencies(steps) do
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

  defp validate_acyclic_dependencies(steps) do
    graph = Map.new(steps, &{&1.id, &1.after})

    graph
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn step_id, :ok ->
      case visit_step(step_id, graph, MapSet.new(), MapSet.new()) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp visit_step(step_id, graph, visiting, visited) do
    cond do
      MapSet.member?(visited, step_id) ->
        :ok

      MapSet.member?(visiting, step_id) ->
        {:error, {:cyclic_lua_workflow_dependency, step_id}}

      true ->
        visiting = MapSet.put(visiting, step_id)
        visited = MapSet.put(visited, step_id)

        graph
        |> Map.get(step_id, [])
        |> Enum.reduce_while(:ok, fn dependency, :ok ->
          case visit_step(dependency, graph, visiting, visited) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp normalize_output(nil, steps), do: {:ok, %{"from" => steps |> List.last() |> Map.fetch!(:id)}}
  defp normalize_output(output, _steps) when is_binary(output), do: {:ok, %{"from" => output}}
  defp normalize_output(output, _steps), do: {:ok, output}

  defp validate_output_refs(output, steps) do
    step_ids = steps |> Enum.map(& &1.id) |> MapSet.new()

    output
    |> Ref.collect()
    |> Enum.reject(&MapSet.member?(step_ids, &1))
    |> case do
      [] -> :ok
      missing -> {:error, {:missing_lua_workflow_output_refs, missing}}
    end
  end

  defp known_value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_key_atom(key), default)
    end
  end

  defp known_key_atom("after"), do: :after
  defp known_key_atom("arguments"), do: :arguments
  defp known_key_atom("args"), do: :args
  defp known_key_atom("depends_on"), do: :depends_on
  defp known_key_atom("id"), do: :id
  defp known_key_atom("name"), do: :name
  defp known_key_atom("output"), do: :output
  defp known_key_atom("retries"), do: :retries
  defp known_key_atom("steps"), do: :steps
  defp known_key_atom("tool"), do: :tool
  defp known_key_atom("tool_id"), do: :tool_id

  defp clamp_retries(retries) when is_integer(retries), do: retries |> max(0) |> min(2)

  defp clamp_retries(retries) when is_binary(retries) do
    case Integer.parse(retries) do
      {parsed, _rest} -> clamp_retries(parsed)
      :error -> 0
    end
  end

  defp clamp_retries(_retries), do: 0
end
