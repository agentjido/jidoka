defmodule Jidoka.Agent.ToolSources.Action do
  @moduledoc false

  alias Jidoka.Agent.Dsl.Tool
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources.Common
  alias Jidoka.Review.Approval

  @spec action_modules(term()) :: [module()]
  def action_modules(%Tool{module: action}), do: [action]

  @spec operations!(term()) :: [Jidoka.Agent.Spec.Operation.t()]
  def operations!(%Tool{module: action} = tool) do
    action
    |> Common.operation_from_action!()
    |> tag_operation(tool)
    |> then(&[&1])
  end

  defp tag_operation(%Operation{metadata: metadata} = operation, %Tool{} = tool) do
    Operation.new!(%Operation{
      operation
      | description: tool.description || operation.description,
        idempotency: tool.idempotency || operation.idempotency,
        metadata: Map.merge(metadata, Common.normalize_metadata!(tool.metadata))
    })
    |> Approval.apply_to_operation!(tool.approval)
  end
end
