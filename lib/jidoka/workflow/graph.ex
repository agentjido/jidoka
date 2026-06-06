defmodule Jidoka.Workflow.Graph do
  @moduledoc false

  alias Jidoka.Projection.Workflow, as: WorkflowProjection
  alias Jidoka.Projection.Value
  alias Jidoka.Workflow.Spec
  alias Jidoka.Workflow.Step

  @spec project(Spec.t()) :: map()
  def project(%Spec{} = spec) do
    %{
      id: spec.id,
      nodes: Enum.map(spec.steps, &node(&1, spec)),
      edges: edges(spec),
      output: WorkflowProjection.ref(spec.output)
    }
  end

  defp node(%Step{} = step, %Spec{} = spec) do
    %{
      name: step.name,
      kind: step.kind,
      dependencies: Map.get(spec.dependencies, step.name, []),
      target: WorkflowProjection.target(step.target),
      condition: WorkflowProjection.ref(step.condition),
      when: WorkflowProjection.ref(step.condition_when),
      unless: WorkflowProjection.ref(step.condition_unless),
      retry: retry(step.retry),
      fanout: fanout(step),
      input: WorkflowProjection.ref(step.input),
      output: output(step)
    }
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new()
  end

  defp edges(%Spec{} = spec) do
    spec.dependencies
    |> Enum.flat_map(fn {to, froms} ->
      Enum.map(froms, fn from -> %{from: from, to: to} end)
    end)
  end

  defp retry(nil), do: nil
  defp retry(retry), do: Value.project(retry)

  defp fanout(%Step{kind: :map} = step) do
    %{
      over: WorkflowProjection.ref(step.over),
      target_kind: step.target_kind,
      max_concurrency: step.max_concurrency
    }
  end

  defp fanout(%Step{kind: :reduce} = step) do
    %{
      over: WorkflowProjection.ref(step.over),
      using: WorkflowProjection.target(step.target)
    }
  end

  defp fanout(_step), do: nil

  defp output(%Step{kind: :gate}), do: :boolean
  defp output(%Step{kind: :map}), do: :list
  defp output(_step), do: nil

  defp empty?(nil), do: true
  defp empty?(%{} = map), do: map_size(map) == 0
  defp empty?([]), do: true
  defp empty?(_value), do: false
end
