defmodule Jidoka.Projection.Turn do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Projection.{Agent, Effect, Memory, Review}
  alias Jidoka.Turn

  @spec project(Turn.Plan.t() | Turn.Request.t() | Turn.State.t() | Turn.Cursor.t() | Turn.Result.t()) :: map()
  def project(%Turn.Plan{} = plan) do
    %{
      spec_id: plan.spec.id,
      workflow_profile: plan.workflow_profile,
      max_model_turns: plan.max_model_turns,
      timeout_ms: plan.timeout_ms,
      phases: plan.phases,
      metadata: Portable.project(plan.metadata)
    }
  end

  def project(%Turn.Request{} = request) do
    %{
      request_id: request.request_id,
      input: request.input,
      content: Portable.project(request.content),
      context: Portable.project(Jidoka.Context.data(request.context)),
      metadata: Portable.project(request.metadata),
      agent_state: Agent.project(request.agent_state)
    }
  end

  def project(%Turn.State{} = state) do
    %{
      spec_id: state.spec.id,
      plan: project(state.plan),
      request: project(state.request),
      agent_state: Agent.project(state.agent_state),
      memory: Memory.project(state.memory),
      prompt: Portable.project(state.prompt),
      context_projection: Portable.project(state.context_projection),
      context_projection_error: Portable.project(state.context_projection_error),
      llm_result: Portable.project(state.llm_result),
      operation_plan: Portable.project(state.operation_plan),
      pending_effects: Enum.map(state.pending_effects, &Effect.project/1),
      pending_interrupt: Review.project(state.pending_interrupt),
      result: state.result,
      result_parts: Portable.project(state.result_parts),
      result_value: Portable.project(state.result_value),
      result_repair_count: state.result_repair_count,
      status: state.status,
      loop_index: state.loop_index,
      started_at_ms: state.started_at_ms,
      journal: Effect.project(state.journal),
      events: Portable.project(state.events),
      diagnostics: Portable.project(state.diagnostics)
    }
  end

  def project(%Turn.Cursor{} = cursor) do
    %{phase: cursor.phase, loop_index: cursor.loop_index, metadata: Portable.project(cursor.metadata)}
  end

  def project(%Turn.Result{} = result) do
    %{
      content: result.content,
      parts: Portable.project(result.parts),
      value: Portable.project(result.value),
      agent_state: Agent.project(result.agent_state),
      journal: Effect.project(result.journal),
      events: Portable.project(result.events),
      usage: Portable.project(result.usage),
      metadata: Portable.project(result.metadata)
    }
  end
end
