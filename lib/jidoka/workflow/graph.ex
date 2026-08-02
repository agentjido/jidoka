defmodule Jidoka.Workflow.Graph do
  @moduledoc false

  alias Jidoka.Projection.Workflow, as: WorkflowProjection
  alias Jidoka.Workflow.Spec

  @spec project(Spec.t()) :: map()
  defdelegate project(spec), to: WorkflowProjection, as: :graph
end
