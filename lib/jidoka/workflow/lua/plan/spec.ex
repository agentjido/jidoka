defmodule Jidoka.Workflow.Lua.Plan.Spec do
  @moduledoc false

  import Jidoka.Workflow.Lua.Plan.Spec.Graph
  import Jidoka.Workflow.Lua.Plan.Spec.Helpers

  alias Jido.Action.Catalog.Entry
  alias Jidoka.Workflow.Lua.Plan.Ref
  alias Jidoka.Workflow.Lua.Policy

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              steps: Zoi.array(Zoi.map()),
              output: Zoi.any()
            },
            coerce: true
          )

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @type step :: %{
          required(:id) => String.t(),
          required(:kind) => :action | :map | :reduce | :gate,
          required(:after) => [String.t()],
          required(:condition) => term() | nil,
          required(:retries) => non_neg_integer(),
          optional(:entry) => Entry.t(),
          optional(:arguments) => map(),
          optional(:map) => map(),
          optional(:reduce) => map(),
          optional(:gate) => map()
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
         {:ok, step} <- fetch_step_kind(raw_step, allowed, workflow_retries),
         {:ok, condition} <- fetch_step_condition(raw_step),
         {:ok, explicit_after} <- fetch_step_after(raw_step) do
      {:ok,
       step
       |> Map.merge(%{
         id: id,
         condition: condition,
         explicit_after: explicit_after,
         after: explicit_after
       })}
    end
  end

  defp normalize_step(raw_step, _allowed, _workflow_retries),
    do: {:error, {:invalid_lua_workflow_step, raw_step}}

  defp fetch_step_kind(raw_step, allowed, workflow_retries) do
    cond do
      has_known_key?(raw_step, "map") ->
        with :ok <- reject_top_level_action_fields(raw_step, "map") do
          normalize_map_step(raw_step, known_value(raw_step, "map", nil), allowed, workflow_retries)
        end

      has_known_key?(raw_step, "reduce") ->
        with :ok <- reject_top_level_action_fields(raw_step, "reduce") do
          normalize_reduce_step(known_value(raw_step, "reduce", nil))
        end

      has_known_key?(raw_step, "gate") ->
        with :ok <- reject_top_level_action_fields(raw_step, "gate") do
          normalize_gate_step(known_value(raw_step, "gate", nil))
        end

      true ->
        normalize_action_step(raw_step, allowed, workflow_retries)
    end
  end

  defp reject_top_level_action_fields(raw_step, kind) do
    conflicting_fields =
      ["tool", "tool_id", "arguments", "args"]
      |> Enum.filter(&has_known_key?(raw_step, &1))

    case conflicting_fields do
      [] -> :ok
      fields -> {:error, {:ambiguous_lua_workflow_step, kind, fields}}
    end
  end

  defp normalize_action_step(raw_step, allowed, workflow_retries) do
    with {:ok, tool_id} <- fetch_step_tool(raw_step),
         {:ok, entry} <- fetch_allowed_entry(allowed, tool_id),
         {:ok, arguments} <- fetch_step_arguments(raw_step) do
      retries =
        raw_step
        |> known_value("retries", workflow_retries)
        |> clamp_retries()

      {:ok, %{kind: :action, entry: entry, arguments: arguments, retries: retries}}
    end
  end

  defp normalize_map_step(raw_step, raw_map, allowed, workflow_retries) when is_map(raw_map) do
    with {:ok, over} <- fetch_required_map_field(raw_map, "over"),
         {:ok, as} <- fetch_map_as(raw_map),
         {:ok, tool_id} <- fetch_map_tool(raw_map),
         {:ok, entry} <- fetch_allowed_entry(allowed, tool_id),
         {:ok, arguments} <- fetch_map_arguments(raw_map) do
      retries =
        raw_map
        |> known_value("retries", known_value(raw_step, "retries", workflow_retries))
        |> clamp_retries()

      {:ok,
       %{
         kind: :map,
         map: %{
           over: over,
           as: as,
           entry: entry,
           arguments: arguments,
           max_items: raw_map |> known_value("max_items", 10) |> clamp_max_items(),
           max_concurrency: raw_map |> known_value("max_concurrency", 8) |> clamp_max_concurrency(),
           retries: retries
         },
         retries: retries
       }}
    end
  end

  defp normalize_map_step(_raw_step, raw_map, _allowed, _workflow_retries),
    do: {:error, {:invalid_lua_workflow_map_step, raw_map}}

  defp normalize_reduce_step(raw_reduce) when is_map(raw_reduce) do
    with {:ok, over} <- fetch_required_map_field(raw_reduce, "over"),
         {:ok, mode} <- fetch_reduce_mode(raw_reduce) do
      {:ok,
       %{
         kind: :reduce,
         reduce: %{
           over: over,
           mode: mode,
           path: known_value(raw_reduce, "path", nil)
         },
         retries: 0
       }}
    end
  end

  defp normalize_reduce_step(raw_reduce), do: {:error, {:invalid_lua_workflow_reduce_step, raw_reduce}}

  defp normalize_gate_step(raw_gate) when is_map(raw_gate) do
    with {:ok, op} <- fetch_gate_op(raw_gate),
         {:ok, left} <- fetch_required_map_field(raw_gate, "left") do
      {:ok,
       %{
         kind: :gate,
         gate: %{
           op: op,
           left: left,
           right: known_value(raw_gate, "right", nil)
         },
         retries: 0
       }}
    end
  end

  defp normalize_gate_step(raw_gate), do: {:error, {:invalid_lua_workflow_gate_step, raw_gate}}

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

  defp fetch_step_condition(raw_step), do: {:ok, known_value(raw_step, "when", nil)}

  defp fetch_required_map_field(map, key) do
    case known_value(map, key, nil) do
      nil -> {:error, {:missing_lua_workflow_field, key}}
      value -> {:ok, value}
    end
  end

  defp fetch_map_as(raw_map) do
    case known_value(raw_map, "as", "item") do
      as when is_binary(as) and as != "" -> {:ok, as}
      as when is_atom(as) and not is_nil(as) -> {:ok, Atom.to_string(as)}
      as -> {:error, {:invalid_lua_workflow_map_as, as}}
    end
  end

  defp fetch_map_tool(raw_map) do
    case known_value(raw_map, "tool", known_value(raw_map, "tool_id", nil)) do
      tool_id when is_binary(tool_id) -> {:ok, tool_id}
      path when is_list(path) -> {:ok, Enum.map_join(path, ".", &to_string/1)}
      tool_id -> {:error, {:invalid_lua_workflow_map_tool, tool_id}}
    end
  end

  defp fetch_map_arguments(raw_map) do
    case known_value(raw_map, "arguments", known_value(raw_map, "args", %{})) do
      nil -> {:ok, %{}}
      arguments when is_map(arguments) -> {:ok, arguments}
      arguments -> {:error, {:invalid_lua_workflow_map_arguments, arguments}}
    end
  end

  defp fetch_reduce_mode(raw_reduce) do
    mode =
      raw_reduce
      |> known_value("mode", "collect")
      |> to_string()

    if mode in ["collect", "count", "sum", "first"] do
      {:ok, mode}
    else
      {:error, {:invalid_lua_workflow_reduce_mode, mode}}
    end
  end

  defp fetch_gate_op(raw_gate) do
    op =
      raw_gate
      |> known_value("op", "exists")
      |> to_string()

    if op in ["exists", "empty", "not_empty", "eq", "neq", "gt", "gte", "lt", "lte", "contains"] do
      {:ok, op}
    else
      {:error, {:invalid_lua_workflow_gate_op, op}}
    end
  end

  defp fetch_step_after(raw_step) do
    case known_value(raw_step, "after", known_value(raw_step, "depends_on", [])) do
      nil -> {:ok, []}
      dependencies when is_list(dependencies) -> {:ok, Enum.map(dependencies, &to_string/1)}
      dependency -> {:ok, [to_string(dependency)]}
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
end
