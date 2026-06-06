defmodule Jidoka.Workflow.Definition do
  @moduledoc false

  alias Jidoka.Workflow
  alias Jidoka.Workflow.Definition.{Graph, Refs, Targets}
  alias Jidoka.Workflow.Spec
  alias Jidoka.Workflow.Step

  @id_regex ~r/^[a-z][a-z0-9_]*$/

  @spec build!(Macro.Env.t(), keyword()) :: Spec.t()
  def build!(%Macro.Env{} = env, opts \\ []) do
    owner_module = env.module
    ensure_callback_opts_absent!(owner_module, opts)

    configured_id = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :id)
    id = resolve_id!(owner_module, configured_id)
    description = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :description)
    metadata = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :metadata, %{})

    input_schema =
      owner_module
      |> Spark.Dsl.Extension.get_opt([:workflow], :input)
      |> resolve_input_schema!(owner_module)

    steps =
      owner_module
      |> Spark.Dsl.Extension.get_entities([:steps])
      |> normalize_steps!(owner_module)

    output =
      owner_module
      |> Spark.Dsl.Extension.get_opt([:workflow_output], :output)
      |> require_output!(owner_module)

    refs = Refs.collect([steps, output])
    output_refs = Refs.collect(output).from

    validate_input_refs!(owner_module, input_schema, refs.input)
    validate_output_refs!(owner_module, output_refs, output)

    dependencies = Graph.infer_dependencies(steps)
    validate_step_refs!(owner_module, steps, dependencies, refs.from)
    sorted_steps = sort_steps!(owner_module, steps, dependencies)

    Spec.new!(
      id: id,
      module: owner_module,
      description: description,
      mode: :dsl,
      input_schema: input_schema,
      parameters_schema: Workflow.ParametersSchema.from_zoi(input_schema),
      steps: sorted_steps,
      dependencies: dependencies,
      output: output,
      input_refs: Enum.sort_by(refs.input, &to_string/1),
      context_refs: Enum.sort_by(refs.context, &to_string/1),
      metadata: metadata || %{}
    )
  end

  defp ensure_callback_opts_absent!(_owner_module, []), do: :ok

  defp ensure_callback_opts_absent!(owner_module, opts) do
    raise_error!(
      owner_module,
      "Jidoka.Workflow cannot mix callback options with the workflow DSL.",
      [:workflow],
      opts,
      "Use either `use Jidoka.Workflow, id: ...` with `run/2`, or `use Jidoka.Workflow` with `workflow do ... end`."
    )
  end

  defp resolve_id!(owner_module, id) do
    normalized_id =
      cond do
        is_atom(id) and not is_nil(id) -> Atom.to_string(id)
        is_binary(id) -> String.trim(id)
        true -> nil
      end

    cond do
      is_nil(normalized_id) ->
        raise_error!(
          owner_module,
          "`workflow.id` is required.",
          [:workflow, :id],
          id,
          "Declare `workflow do id :my_workflow end` using lower snake case."
        )

      Regex.match?(@id_regex, normalized_id) ->
        normalized_id

      true ->
        raise_error!(
          owner_module,
          "`workflow.id` must be lower snake case.",
          [:workflow, :id],
          id,
          "Use a value like `research_pipeline` with lowercase letters, numbers, and underscores."
        )
    end
  end

  defp resolve_input_schema!(nil, owner_module) do
    raise_error!(
      owner_module,
      "`workflow.input` is required.",
      [:workflow, :input],
      nil,
      "Declare `input Zoi.object(%{field: Zoi.string()})` inside `workflow do ... end`."
    )
  end

  defp resolve_input_schema!(%Zoi.Types.Map{} = schema, _owner_module), do: schema

  defp resolve_input_schema!(schema, owner_module) do
    raise_error!(
      owner_module,
      "`workflow.input` must be a Zoi map/object schema.",
      [:workflow, :input],
      schema,
      "Use `input Zoi.object(%{field: Zoi.string()})`."
    )
  end

  defp require_output!(nil, owner_module) do
    raise_error!(
      owner_module,
      "`output` is required for a Jidoka workflow.",
      [:workflow_output, :output],
      nil,
      "Declare `output from(:step_name)` at module top level."
    )
  end

  defp require_output!(output, _owner_module), do: output

  defp normalize_steps!([], owner_module) do
    raise_error!(
      owner_module,
      "A Jidoka workflow must declare at least one step.",
      [:steps],
      [],
      "Add a `steps do ... end` block with at least one `action`, `function`, or `agent` step."
    )
  end

  defp normalize_steps!(raw_steps, owner_module) do
    steps = Enum.map(raw_steps, &normalize_step!(&1, owner_module))
    ensure_unique_step_names!(owner_module, steps)
    steps
  end

  defp normalize_step!(%Jidoka.Workflow.Dsl.ActionStep{} = step, owner_module) do
    validate_step_name!(owner_module, step.name, [:steps, :action])
    Targets.validate_action!(owner_module, step)

    Step.new!(
      kind: :action,
      name: step.name,
      target: step.module,
      input: step.input || %{},
      after: step.after || [],
      metadata: step.metadata || %{}
    )
  end

  defp normalize_step!(%Jidoka.Workflow.Dsl.FunctionStep{} = step, owner_module) do
    validate_step_name!(owner_module, step.name, [:steps, :function])
    Targets.validate_function!(owner_module, step)

    Step.new!(
      kind: :function,
      name: step.name,
      target: step.mfa,
      input: step.input || %{},
      after: step.after || [],
      metadata: step.metadata || %{}
    )
  end

  defp normalize_step!(%Jidoka.Workflow.Dsl.AgentStep{} = step, owner_module) do
    validate_step_name!(owner_module, step.name, [:steps, :agent])
    Targets.validate_agent!(owner_module, step)

    Step.new!(
      kind: :agent,
      name: step.name,
      target: step.agent,
      prompt: step.prompt,
      context: step.context || %{},
      after: step.after || [],
      metadata: step.metadata || %{}
    )
  end

  defp validate_step_name!(owner_module, name, path) when is_atom(name) do
    if Regex.match?(@id_regex, Atom.to_string(name)) do
      :ok
    else
      raise_error!(
        owner_module,
        "Workflow step names must be lower snake case.",
        path ++ [:name],
        name,
        "Use a step name like `plan_queries`."
      )
    end
  end

  defp validate_step_name!(owner_module, name, path) do
    raise_error!(
      owner_module,
      "Workflow step names must be atoms.",
      path ++ [:name],
      name,
      "Use a lower snake case atom like `:plan_queries`."
    )
  end

  defp ensure_unique_step_names!(owner_module, steps) do
    duplicate =
      steps
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.find(fn {_name, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {name, _count} ->
        raise_error!(
          owner_module,
          "Workflow step `#{name}` is declared more than once.",
          [:steps, name],
          name,
          "Use unique step names within a workflow."
        )
    end
  end

  defp validate_step_refs!(owner_module, steps, dependencies, all_from_refs) do
    names = MapSet.new(Enum.map(steps, & &1.name))

    Enum.each(dependencies, fn {step_name, refs} ->
      Enum.each(refs, &validate_step_dependency_ref!(owner_module, names, step_name, &1))
    end)

    Enum.each(all_from_refs, &validate_from_ref!(owner_module, names, &1))
  end

  defp validate_output_refs!(_owner_module, [_first | _rest], _output), do: :ok

  defp validate_output_refs!(owner_module, [], output) do
    raise_error!(
      owner_module,
      "Workflow output must reference at least one step.",
      [:workflow_output, :output],
      output,
      "Use `output from(:step_name)` or return a map containing `from(:step_name)`."
    )
  end

  defp validate_step_dependency_ref!(owner_module, names, step_name, ref) do
    if MapSet.member?(names, ref) do
      :ok
    else
      raise_error!(
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
      raise_error!(
        owner_module,
        "Workflow output or step input references missing step `#{ref}`.",
        [:workflow_output, :output],
        ref,
        "Reference an existing step with `from(:step)`."
      )
    end
  end

  defp validate_input_refs!(owner_module, input_schema, input_refs) do
    Enum.each(input_refs, fn key ->
      unless schema_has_key?(input_schema, key) do
        raise_error!(
          owner_module,
          "Workflow input reference `#{key}` is not declared in `workflow.input`.",
          [:workflow, :input],
          key,
          "Add the field to `input Zoi.object(%{...})` or remove the `input/1` reference."
        )
      end
    end)
  end

  defp schema_has_key?(%Zoi.Types.Map{fields: fields}, key) when is_list(fields) do
    Enum.any?(fields, fn {field, _schema} -> equivalent_key?(field, key) end)
  end

  defp schema_has_key?(_schema, _key), do: false

  defp equivalent_key?(left, right), do: left == right or to_string(left) == to_string(right)

  defp sort_steps!(owner_module, steps, dependencies) do
    case Graph.sort_steps(steps, dependencies) do
      {:ok, sorted_names} ->
        sorted_names

      {:error, cyclic_names} ->
        raise_error!(
          owner_module,
          "Workflow step dependencies contain a cycle.",
          [:steps],
          Enum.sort(cyclic_names),
          "Remove the circular `from/1`, `from/2`, or `after:` dependency."
        )
    end
  end

  defp raise_error!(owner_module, message, path, value, hint) do
    raise Jidoka.Workflow.Dsl.Error.exception(
            message: message,
            path: path,
            value: value,
            hint: hint,
            module: owner_module
          )
  end
end
