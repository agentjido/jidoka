defmodule Jidoka.Projection.Effect do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Portable

  @spec project(
          Effect.Journal.t()
          | Effect.Intent.t()
          | Effect.LLMDecision.t()
          | Effect.OperationGroup.t()
          | Effect.OperationRequest.t()
          | Effect.OperationResult.t()
          | Effect.Result.t()
        ) :: map()
  def project(%Effect.Journal{} = journal) do
    %{
      intents: journal.intents |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&project/1),
      results:
        journal.results
        |> Map.values()
        |> Enum.sort_by(& &1.intent_id)
        |> Enum.map(&project/1),
      operation_groups:
        journal.operation_groups
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&project/1)
    }
  end

  def project(%Effect.OperationGroup{} = group) do
    %{
      id: group.id,
      intent_ids: group.intent_ids,
      started_intent_ids: group.started_intent_ids,
      completed_intent_ids: group.completed_intent_ids,
      status: group.status
    }
  end

  def project(%Effect.Intent{} = intent) do
    %{
      id: intent.id,
      kind: intent.kind,
      payload: Portable.project(intent.payload),
      idempotency_key: intent.idempotency_key,
      idempotency: intent.idempotency,
      metadata: Portable.project(intent.metadata)
    }
  end

  def project(%Effect.LLMDecision{} = decision) do
    decision
    |> Effect.LLMDecision.to_payload()
    |> Map.put(:metadata, Portable.project(decision.metadata))
  end

  def project(%Effect.OperationRequest{} = request) do
    request |> Effect.OperationRequest.to_payload() |> Portable.project()
  end

  def project(%Effect.OperationResult{} = result) do
    %{
      operation: result.operation,
      arguments: Portable.project(result.arguments),
      output: Portable.project(result.output),
      content: result.content,
      request_id: result.request_id,
      loop_index: result.loop_index,
      effect_id: result.effect_id,
      metadata: Portable.project(result.metadata)
    }
    |> reject_nil_values()
  end

  def project(%Effect.Result{} = result) do
    %{
      intent_id: result.intent_id,
      kind: result.kind,
      status: result.status,
      output: Portable.project(result.output),
      metadata: Portable.project(result.metadata)
    }
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
