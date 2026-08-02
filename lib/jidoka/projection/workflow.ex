defmodule Jidoka.Projection.Workflow do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Workflow

  @spec project(Workflow.Spec.t() | Workflow.Step.t()) :: map()
  def project(%Workflow.Spec{} = workflow) do
    %{
      id: workflow.id,
      module: inspect(workflow.module),
      description: workflow.description,
      mode: workflow.mode,
      parameters_schema?: is_map(workflow.parameters_schema),
      steps: Enum.map(workflow.steps, &project/1),
      dependencies: Portable.project(workflow.dependencies),
      output: ref(workflow.output),
      graph: Workflow.Graph.project(workflow),
      input_refs: Enum.map(workflow.input_refs, &Portable.project/1),
      context_refs: Enum.map(workflow.context_refs, &Portable.project/1),
      metadata: Portable.project(workflow.metadata)
    }
  end

  def project(%Workflow.Step{} = step) do
    %{
      name: step.name,
      kind: step.kind,
      target: target(step.target),
      target_kind: step.target_kind,
      input: ref(step.input),
      prompt: ref(step.prompt),
      context: ref(step.context),
      condition: ref(step.condition),
      when: ref(step.condition_when),
      unless: ref(step.condition_unless),
      over: ref(step.over),
      using: target(step.using),
      max_concurrency: step.max_concurrency,
      after: step.after,
      retry: Portable.project(step.retry),
      metadata: Portable.project(step.metadata)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec target(term()) :: term()
  def target({module, function, arity})
      when is_atom(module) and is_atom(function) and is_integer(arity) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  def target(target) when is_atom(target), do: inspect(target)
  def target(target), do: Portable.project(target)

  @spec ref(term()) :: term()
  def ref({:jidoka_workflow_ref, :input, key}), do: %{ref: :input, key: key}
  def ref({:jidoka_workflow_ref, :context, key}), do: %{ref: :context, key: key}
  def ref({:jidoka_workflow_ref, :value, value}), do: %{ref: :value, value: Portable.project(value)}
  def ref({:jidoka_workflow_ref, :from, step, nil}), do: %{ref: :from, step: step}
  def ref({:jidoka_workflow_ref, :from, step, path}), do: %{ref: :from, step: step, path: path}
  def ref({:jidoka_workflow_ref, :maybe_from, step, nil}), do: %{ref: :maybe_from, step: step}
  def ref({:jidoka_workflow_ref, :maybe_from, step, path}), do: %{ref: :maybe_from, step: step, path: path}
  def ref({:jidoka_workflow_ref, :coalesce, values}), do: %{ref: :coalesce, values: Enum.map(values, &ref/1)}
  def ref({:jidoka_workflow_ref, :item}), do: %{ref: :item}
  def ref({:jidoka_workflow_ref, :index}), do: %{ref: :index}
  def ref({:jidoka_workflow_ref, :items}), do: %{ref: :items}
  def ref({:jidoka_workflow_ref, :loop_state}), do: %{ref: :loop_state}
  def ref({:jidoka_workflow_ref, :iteration}), do: %{ref: :iteration}
  def ref(%{} = map), do: Map.new(map, fn {key, value} -> {key, ref(value)} end)
  def ref(list) when is_list(list), do: Enum.map(list, &ref/1)
  def ref(nil), do: nil
  def ref(value), do: Portable.project(value)
end
