defmodule Jidoka.Workflow.Definition do
  @moduledoc false

  alias Jidoka.Workflow
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

    refs = collect_refs([steps, output])
    output_refs = collect_refs(output).from

    validate_input_refs!(owner_module, input_schema, refs.input)
    validate_output_refs!(owner_module, output_refs, output)

    dependencies = infer_dependencies(steps)
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
    validate_action_target!(owner_module, step)

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
    validate_function_target!(owner_module, step)

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
    validate_agent_target!(owner_module, step)

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

  defp validate_action_target!(owner_module, step) do
    cond do
      not is_atom(step.module) ->
        raise_error!(
          owner_module,
          "Workflow action step target is not a valid action-backed module.",
          [:steps, step.name, :action],
          step.module,
          "Use a module defined with `use Jidoka.Action` or another Jido action module exposing `to_tool/0`."
        )

      Code.ensure_loaded?(step.module) and function_exported?(step.module, :to_tool, 0) ->
        :ok

      Code.ensure_loaded?(step.module) ->
        raise_error!(
          owner_module,
          "Workflow action step target is not a valid action-backed module.",
          [:steps, step.name, :action],
          step.module,
          "Use a module defined with `use Jidoka.Action` or another Jido action module exposing `to_tool/0`."
        )

      true ->
        :ok
    end
  end

  defp validate_function_target!(owner_module, %{mfa: {module, function, 2}} = step)
       when is_atom(module) and is_atom(function) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, function, 2) ->
        :ok

      Code.ensure_loaded?(module) ->
        raise_error!(
          owner_module,
          "Workflow function step target is not exported.",
          [:steps, step.name, :function],
          {module, function, 2},
          "Use a `{module, function, 2}` tuple for a public function."
        )

      true ->
        :ok
    end
  end

  defp validate_function_target!(owner_module, step) do
    raise_error!(
      owner_module,
      "Workflow function steps require a `{module, function, 2}` target.",
      [:steps, step.name, :function],
      step.mfa,
      "Use `function :normalize, {MyApp.WorkflowFns, :normalize, 2}, input: ...`."
    )
  end

  defp validate_agent_target!(owner_module, %{agent: module} = step) when is_atom(module) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :run_turn, 2) ->
        :ok

      Code.ensure_loaded?(module) ->
        raise_error!(
          owner_module,
          "Workflow agent step target is not a Jidoka-compatible agent.",
          [:steps, step.name, :agent],
          module,
          "Use a compiled Jidoka agent module exposing `run_turn/2`."
        )

      true ->
        :ok
    end
  end

  defp validate_agent_target!(owner_module, step) do
    raise_error!(
      owner_module,
      "Workflow agent steps require a Jidoka agent module target.",
      [:steps, step.name, :agent],
      step.agent,
      "Use `agent :draft, MyApp.Agents.Writer, prompt: ...`."
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

  defp infer_dependencies(steps) do
    Map.new(steps, fn step ->
      refs =
        step
        |> step_ref_terms()
        |> collect_refs()

      dependencies =
        refs.from
        |> Enum.concat(step.after)
        |> Enum.uniq()

      {step.name, dependencies}
    end)
  end

  defp step_ref_terms(%Step{kind: :action} = step), do: [step.input]
  defp step_ref_terms(%Step{kind: :function} = step), do: [step.input]
  defp step_ref_terms(%Step{kind: :agent} = step), do: [step.prompt, step.context]

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
    order = Enum.map(steps, & &1.name)
    by_name = Map.new(steps, &{&1.name, &1})

    case topo_sort(dependencies, order, []) do
      {:ok, sorted_names} ->
        Enum.map(sorted_names, &Map.fetch!(by_name, &1))

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

  defp collect_refs(term), do: collect_refs(term, %{input: [], from: [], context: []})

  defp collect_refs({:jidoka_workflow_ref, :input, key}, acc),
    do: Map.update!(acc, :input, &[key | &1])

  defp collect_refs({:jidoka_workflow_ref, :from, step, _path}, acc),
    do: Map.update!(acc, :from, &[step | &1])

  defp collect_refs({:jidoka_workflow_ref, :context, key}, acc),
    do: Map.update!(acc, :context, &[key | &1])

  defp collect_refs({:jidoka_workflow_ref, :value, _value}, acc), do: acc

  defp collect_refs(%{} = map, acc), do: Enum.reduce(Map.values(map), acc, &collect_refs/2)

  defp collect_refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_refs/2)

  defp collect_refs(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_refs/2)
  end

  defp collect_refs(_other, acc) do
    %{
      input: Enum.uniq(acc.input),
      from: Enum.uniq(acc.from),
      context: Enum.uniq(acc.context)
    }
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
