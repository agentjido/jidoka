defmodule Jidoka.Agent.ToolSources.Workflow do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Workflow
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Workflow, as: WorkflowSource

  @spec source!(term()) :: WorkflowSource.t()
  def source!(%Workflow{} = workflow) do
    WorkflowSource.new!(
      workflow: workflow.workflow,
      as: workflow.as,
      description: workflow.description,
      timeout: workflow.timeout || 30_000,
      async: workflow.async || false,
      max_concurrency: workflow.max_concurrency,
      forward_context: workflow.forward_context || :public,
      result: workflow.result || :output,
      idempotency: workflow.idempotency || :idempotent,
      metadata: workflow.metadata || %{}
    )
  end

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Workflow{} = workflow) do
    workflow
    |> source!()
    |> Source.operations()
    |> case do
      {:ok, operations} -> operations
      {:error, reason} -> raise ArgumentError, "invalid workflow source: #{inspect(reason)}"
    end
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%Workflow{} = workflow) do
    source = source!(workflow)

    [
      %{
        "source" => "workflow",
        "name" => source.name,
        "workflow" => source.definition.id,
        "module" => inspect(source.workflow),
        "timeout" => source.timeout,
        "async" => source.async,
        "max_concurrency" => source.max_concurrency,
        "forward_context" => inspect(source.forward_context),
        "result" => Atom.to_string(source.result)
      }
      |> Common.reject_nil_values()
    ]
  end
end
