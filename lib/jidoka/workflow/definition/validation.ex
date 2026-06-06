defmodule Jidoka.Workflow.Definition.Validation do
  @moduledoc false

  alias Jidoka.Workflow.Definition.{Error, Graph, Refs}

  @id_regex ~r/^[a-z][a-z0-9_]*$/

  @spec ensure_callback_opts_absent!(module(), keyword()) :: :ok
  def ensure_callback_opts_absent!(_owner_module, []), do: :ok

  def ensure_callback_opts_absent!(owner_module, opts) do
    Error.raise!(
      owner_module,
      "Jidoka.Workflow cannot mix callback options with the workflow DSL.",
      [:workflow],
      opts,
      "Use either `use Jidoka.Workflow, id: ...` with `run/2`, or `use Jidoka.Workflow` with `workflow do ... end`."
    )
  end

  @spec resolve_id!(module(), term()) :: String.t()
  def resolve_id!(owner_module, id) do
    normalized_id =
      cond do
        is_atom(id) and not is_nil(id) -> Atom.to_string(id)
        is_binary(id) -> String.trim(id)
        true -> nil
      end

    cond do
      is_nil(normalized_id) ->
        Error.raise!(
          owner_module,
          "`workflow.id` is required.",
          [:workflow, :id],
          id,
          "Declare `workflow do id :my_workflow end` using lower snake case."
        )

      Regex.match?(@id_regex, normalized_id) ->
        normalized_id

      true ->
        Error.raise!(
          owner_module,
          "`workflow.id` must be lower snake case.",
          [:workflow, :id],
          id,
          "Use a value like `research_pipeline` with lowercase letters, numbers, and underscores."
        )
    end
  end

  @spec resolve_input_schema!(term(), module()) :: Zoi.schema()
  def resolve_input_schema!(nil, owner_module) do
    Error.raise!(
      owner_module,
      "`workflow.input` is required.",
      [:workflow, :input],
      nil,
      "Declare `input Zoi.object(%{field: Zoi.string()})` inside `workflow do ... end`."
    )
  end

  def resolve_input_schema!(%Zoi.Types.Map{} = schema, _owner_module), do: schema

  def resolve_input_schema!(schema, owner_module) do
    Error.raise!(
      owner_module,
      "`workflow.input` must be a Zoi map/object schema.",
      [:workflow, :input],
      schema,
      "Use `input Zoi.object(%{field: Zoi.string()})`."
    )
  end

  @spec require_output!(term(), module()) :: term()
  def require_output!(nil, owner_module) do
    Error.raise!(
      owner_module,
      "`output` is required for a Jidoka workflow.",
      [:workflow_output, :output],
      nil,
      "Declare `output from(:step_name)` at module top level."
    )
  end

  def require_output!(output, _owner_module), do: output

  @spec validate_required!(module(), term(), [term()], String.t()) :: :ok
  def validate_required!(_owner_module, value, _path, _message) when not is_nil(value), do: :ok

  def validate_required!(owner_module, value, path, message) do
    Error.raise!(owner_module, message, path, value, "Provide the required workflow step option.")
  end

  @spec validate_no_special_refs!(module(), [term()], term()) :: :ok
  def validate_no_special_refs!(owner_module, path, term) do
    validate_allowed_special_refs!(owner_module, path, term, [])
  end

  @spec validate_allowed_special_refs!(module(), [term()], term(), [atom()]) :: :ok
  def validate_allowed_special_refs!(owner_module, path, term, allowed) do
    invalid =
      term
      |> Refs.special_kinds()
      |> Enum.reject(&(&1 in allowed))

    case invalid do
      [] ->
        :ok

      invalid ->
        Error.raise!(
          owner_module,
          "Workflow special refs are not valid here.",
          path,
          invalid,
          "Use `item()` and `index()` only inside map input, and `items()` only inside reduce input."
        )
    end
  end

  @spec validate_step_name!(module(), term(), [term()]) :: :ok
  def validate_step_name!(owner_module, name, path) when is_atom(name) do
    if Regex.match?(@id_regex, Atom.to_string(name)) do
      :ok
    else
      Error.raise!(
        owner_module,
        "Workflow step names must be lower snake case.",
        path ++ [:name],
        name,
        "Use a step name like `plan_queries`."
      )
    end
  end

  def validate_step_name!(owner_module, name, path) do
    Error.raise!(
      owner_module,
      "Workflow step names must be atoms.",
      path ++ [:name],
      name,
      "Use a lower snake case atom like `:plan_queries`."
    )
  end

  @spec ensure_unique_step_names!(module(), [Jidoka.Workflow.Step.t()]) :: :ok
  def ensure_unique_step_names!(owner_module, steps) do
    duplicate =
      steps
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.find(fn {_name, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {name, _count} ->
        Error.raise!(
          owner_module,
          "Workflow step `#{name}` is declared more than once.",
          [:steps, name],
          name,
          "Use unique step names within a workflow."
        )
    end
  end

  @spec validate_input_refs!(module(), Zoi.schema(), [term()]) :: :ok
  def validate_input_refs!(owner_module, input_schema, input_refs) do
    Enum.each(input_refs, fn key ->
      unless schema_has_key?(input_schema, key) do
        Error.raise!(
          owner_module,
          "Workflow input reference `#{key}` is not declared in `workflow.input`.",
          [:workflow, :input],
          key,
          "Add the field to `input Zoi.object(%{...})` or remove the `input/1` reference."
        )
      end
    end)
  end

  @spec validate_output_refs!(module(), [atom()], term()) :: :ok
  def validate_output_refs!(_owner_module, [_first | _rest], _output), do: :ok

  def validate_output_refs!(owner_module, [], output) do
    Error.raise!(
      owner_module,
      "Workflow output must reference at least one step.",
      [:workflow_output, :output],
      output,
      "Use `output from(:step_name)` or return a map containing `from(:step_name)`."
    )
  end

  @spec validate_step_refs!(module(), [Jidoka.Workflow.Step.t()], map(), [atom()]) :: :ok
  def validate_step_refs!(owner_module, steps, dependencies, all_from_refs) do
    names = MapSet.new(Enum.map(steps, & &1.name))

    Enum.each(dependencies, fn {step_name, refs} ->
      Enum.each(refs, &validate_step_dependency_ref!(owner_module, names, step_name, &1))
    end)

    Enum.each(all_from_refs, &validate_from_ref!(owner_module, names, &1))
  end

  @spec sort_steps!(module(), [Jidoka.Workflow.Step.t()], map()) :: [Jidoka.Workflow.Step.t()]
  def sort_steps!(owner_module, steps, dependencies) do
    case Graph.sort_steps(steps, dependencies) do
      {:ok, sorted_steps} ->
        sorted_steps

      {:error, cyclic_names} ->
        Error.raise!(
          owner_module,
          "Workflow step dependencies contain a cycle.",
          [:steps],
          Enum.sort(cyclic_names),
          "Remove the circular `from/1`, `from/2`, or `after:` dependency."
        )
    end
  end

  defp validate_step_dependency_ref!(owner_module, names, step_name, ref) do
    if MapSet.member?(names, ref) do
      :ok
    else
      Error.raise!(
        owner_module,
        "Workflow step `#{step_name}` references missing step `#{ref}`.",
        [:steps, step_name],
        ref,
        "Reference an existing step with `from(:step)` or `after: [:step]`."
      )
    end
  end

  defp validate_from_ref!(owner_module, names, ref) do
    if MapSet.member?(names, ref) do
      :ok
    else
      Error.raise!(
        owner_module,
        "Workflow output or step input references missing step `#{ref}`.",
        [:workflow_output, :output],
        ref,
        "Reference an existing step with `from(:step)`."
      )
    end
  end

  defp schema_has_key?(%Zoi.Types.Map{fields: fields}, key) when is_list(fields) do
    Enum.any?(fields, fn {field, _schema} -> equivalent_key?(field, key) end)
  end

  defp schema_has_key?(_schema, _key), do: false

  defp equivalent_key?(left, right), do: left == right or to_string(left) == to_string(right)
end
