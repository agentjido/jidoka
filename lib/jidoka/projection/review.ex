defmodule Jidoka.Projection.Review do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Review

  @spec project(Review.Interrupt.t() | Review.Request.t() | Review.Response.t() | nil) :: map() | nil
  def project(nil), do: nil

  def project(%Review.Interrupt{} = interrupt) do
    %{
      id: interrupt.id,
      boundary: interrupt.boundary,
      control: interrupt.control_name,
      reason: Portable.project(interrupt.reason),
      agent_id: interrupt.agent_id,
      request_id: interrupt.request_id,
      loop_index: interrupt.loop_index,
      effect_id: interrupt.effect_id,
      effect_kind: interrupt.effect_kind,
      operation: interrupt.operation,
      operation_kind: interrupt.operation_kind,
      arguments: Portable.project(interrupt.arguments),
      idempotency: interrupt.idempotency,
      idempotency_key: interrupt.idempotency_key,
      created_at_ms: interrupt.created_at_ms,
      expires_at_ms: interrupt.expires_at_ms,
      metadata: Portable.project(interrupt.metadata)
    }
  end

  def project(%Review.Request{} = request) do
    %{
      id: request.id,
      interrupt_id: request.interrupt_id,
      agent_id: request.agent_id,
      request_id: request.request_id,
      boundary: request.boundary,
      operation: request.operation,
      arguments: Portable.project(request.arguments),
      reason: Portable.project(request.reason),
      created_at_ms: request.created_at_ms,
      expires_at_ms: request.expires_at_ms,
      metadata: Portable.project(request.metadata)
    }
  end

  def project(%Review.Response{} = response) do
    %{
      interrupt_id: response.interrupt_id,
      decision: response.decision,
      reason: Portable.project(response.reason),
      responded_at_ms: response.responded_at_ms,
      metadata: Portable.project(response.metadata)
    }
  end
end
