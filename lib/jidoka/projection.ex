defmodule Jidoka.Projection do
  @moduledoc """
  Stable public projections for Jidoka data contracts.

  Projections are intentionally smaller than raw structs. They omit live or
  implementation-specific values such as Zoi schemas, full LLMDB structs, and
  Spark module metadata while preserving the semantic shape needed by docs,
  golden tests, inspection, traces, and replay scaffolding.
  """

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Handoff
  alias Jidoka.Harness
  alias Jidoka.Projection.AgentSpec, as: AgentSpecProjection
  alias Jidoka.Projection.Value
  alias Jidoka.Projection.Workflow, as: WorkflowProjection
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn
  alias Jidoka.Workflow

  @doc "Projects a supported Jidoka data contract into a stable map."
  @spec project(term()) :: term()
  def project(%Agent.Spec{} = spec), do: AgentSpecProjection.project(spec)
  def project(%Agent.Spec.Generation{} = generation), do: AgentSpecProjection.project(generation)
  def project(%Agent.Spec.Result{} = result), do: AgentSpecProjection.project(result)
  def project(%Agent.Spec.Memory{} = memory), do: AgentSpecProjection.project(memory)
  def project(%Agent.Spec.Operation{} = operation), do: AgentSpecProjection.project(operation)

  def project(%Workflow.Spec{} = workflow) do
    %{
      id: workflow.id,
      module: inspect(workflow.module),
      description: workflow.description,
      mode: workflow.mode,
      parameters_schema?: is_map(workflow.parameters_schema),
      steps: Enum.map(workflow.steps, &project/1),
      dependencies: Value.project(workflow.dependencies),
      output: WorkflowProjection.ref(workflow.output),
      graph: Workflow.Graph.project(workflow),
      input_refs: Enum.map(workflow.input_refs, &Value.project/1),
      context_refs: Enum.map(workflow.context_refs, &Value.project/1),
      metadata: Value.project(workflow.metadata)
    }
  end

  def project(%Workflow.Step{} = step) do
    %{
      name: step.name,
      kind: step.kind,
      target: WorkflowProjection.target(step.target),
      target_kind: step.target_kind,
      input: WorkflowProjection.ref(step.input),
      prompt: WorkflowProjection.ref(step.prompt),
      context: WorkflowProjection.ref(step.context),
      condition: WorkflowProjection.ref(step.condition),
      when: WorkflowProjection.ref(step.condition_when),
      unless: WorkflowProjection.ref(step.condition_unless),
      over: WorkflowProjection.ref(step.over),
      using: WorkflowProjection.target(step.using),
      max_concurrency: step.max_concurrency,
      after: step.after,
      retry: Value.project(step.retry),
      metadata: Value.project(step.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Handoff{} = handoff) do
    %{
      id: handoff.id,
      conversation_id: handoff.conversation_id,
      from_agent: Value.project(handoff.from_agent),
      to_agent: inspect(handoff.to_agent),
      to_agent_id: handoff.to_agent_id,
      name: handoff.name,
      message: handoff.message,
      summary: handoff.summary,
      reason: handoff.reason,
      context: Value.project(handoff.context),
      request_id: handoff.request_id,
      metadata: Value.project(handoff.metadata)
    }
  end

  def project(%Agent.Spec.Controls{} = controls), do: AgentSpecProjection.project(controls)
  def project(%Agent.Spec.Controls.Input{} = input), do: AgentSpecProjection.project(input)
  def project(%Agent.Spec.Controls.Output{} = output), do: AgentSpecProjection.project(output)
  def project(%Agent.Spec.Controls.Operation{} = operation_control), do: AgentSpecProjection.project(operation_control)

  def project(%Turn.Plan{} = plan) do
    %{
      spec_id: plan.spec.id,
      workflow_profile: plan.workflow_profile,
      max_model_turns: plan.max_model_turns,
      timeout_ms: plan.timeout_ms,
      phases: plan.phases,
      metadata: Value.project(plan.metadata)
    }
  end

  def project(%Turn.Request{} = request) do
    %{
      request_id: request.request_id,
      input: request.input,
      context: Value.project(request.context),
      metadata: Value.project(request.metadata),
      agent_state: project(request.agent_state)
    }
  end

  def project(%Agent.State{} = state) do
    %{
      messages: Enum.map(state.messages, &project/1),
      operation_results: Enum.map(state.operation_results, &project/1),
      metadata: Value.project(state.metadata)
    }
  end

  def project(%Agent.Message{} = message), do: Agent.Message.to_map(message)

  def project(%Turn.State{} = state) do
    %{
      spec_id: state.spec.id,
      plan: project(state.plan),
      request: project(state.request),
      agent_state: project(state.agent_state),
      memory: project(state.memory),
      prompt: Value.project(state.prompt),
      llm_result: Value.project(state.llm_result),
      operation_plan: Value.project(state.operation_plan),
      pending_effects: Enum.map(state.pending_effects, &project/1),
      pending_interrupt: project(state.pending_interrupt),
      result: state.result,
      result_value: Value.project(state.result_value),
      result_repair_count: state.result_repair_count,
      status: state.status,
      loop_index: state.loop_index,
      started_at_ms: state.started_at_ms,
      journal: project(state.journal),
      events: Value.project(state.events),
      diagnostics: Value.project(state.diagnostics)
    }
  end

  def project(%Turn.Cursor{} = cursor) do
    %{
      phase: cursor.phase,
      loop_index: cursor.loop_index,
      metadata: Value.project(cursor.metadata)
    }
  end

  def project(%Turn.Result{} = result) do
    %{
      content: result.content,
      value: Value.project(result.value),
      agent_state: project(result.agent_state),
      journal: project(result.journal),
      events: Value.project(result.events),
      usage: Value.project(result.usage),
      metadata: Value.project(result.metadata)
    }
  end

  def project(%Effect.Journal{} = journal) do
    %{
      intents:
        journal.intents
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&project/1),
      results:
        journal.results
        |> Map.values()
        |> Enum.sort_by(& &1.intent_id)
        |> Enum.map(&project/1)
    }
  end

  def project(%Effect.Intent{} = intent) do
    %{
      id: intent.id,
      kind: intent.kind,
      payload: Value.project(intent.payload),
      idempotency_key: intent.idempotency_key,
      idempotency: intent.idempotency,
      metadata: Value.project(intent.metadata)
    }
  end

  def project(%Effect.LLMDecision{} = decision) do
    decision
    |> Effect.LLMDecision.to_payload()
    |> Map.put(:metadata, Value.project(decision.metadata))
  end

  def project(%Effect.OperationRequest{} = request) do
    request
    |> Effect.OperationRequest.to_payload()
    |> Value.project()
  end

  def project(%Effect.OperationResult{} = result) do
    %{
      operation: result.operation,
      arguments: Value.project(result.arguments),
      output: Value.project(result.output),
      content: result.content,
      request_id: result.request_id,
      loop_index: result.loop_index,
      effect_id: result.effect_id,
      metadata: Value.project(result.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Effect.Result{} = result) do
    %{
      intent_id: result.intent_id,
      kind: result.kind,
      status: result.status,
      output: Value.project(result.output),
      metadata: Value.project(result.metadata)
    }
  end

  def project(%Jidoka.Memory.Entry{} = entry) do
    %{
      id: entry.id,
      agent_id: entry.agent_id,
      session_id: entry.session_id,
      content: entry.content,
      metadata: Value.project(entry.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Jidoka.Memory.RecallRequest{} = request) do
    %{
      agent_id: request.agent_id,
      session_id: request.session_id,
      scope: request.scope,
      query: request.query,
      limit: request.limit,
      metadata: Value.project(request.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Jidoka.Memory.RecallResult{} = result) do
    %{
      request: project(result.request),
      entries: Enum.map(result.entries, &project/1),
      metadata: Value.project(result.metadata)
    }
  end

  def project(%Jidoka.Memory.WriteRequest{} = request) do
    %{
      entry: project(request.entry),
      metadata: Value.project(request.metadata)
    }
  end

  def project(%Jidoka.Memory.WriteResult{} = result) do
    %{
      request: project(result.request),
      entry: project(result.entry),
      status: result.status,
      metadata: Value.project(result.metadata)
    }
  end

  def project(%AgentSnapshot{} = snapshot) do
    %{
      schema_version: snapshot.schema_version,
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: project(snapshot.cursor),
      turn_state: project(snapshot.turn_state),
      metadata: Value.project(snapshot.metadata)
    }
  end

  def project(%Harness.Session{} = session) do
    %{
      schema_version: session.schema_version,
      session_id: session.session_id,
      agent_id: session.agent_id,
      status: session.status,
      requests: Enum.map(session.requests, &project/1),
      snapshots: Enum.map(session.snapshots, &project/1),
      result: project(session.result),
      pending_reviews: Enum.map(session.pending_reviews, &project/1),
      error: Value.project(session.error),
      metadata: Value.project(session.metadata)
    }
  end

  def project(%Harness.Replay{} = replay) do
    replay
    |> Map.from_struct()
    |> Value.project()
  end

  def project(%Jidoka.Debug.RequestSummary{} = summary) do
    summary
    |> Map.from_struct()
    |> Value.project()
  end

  def project(%Jidoka.Debug.ReplayDiagnostics{} = diagnostics) do
    diagnostics
    |> Map.from_struct()
    |> Value.project()
  end

  def project(%Jidoka.Trace.Policy{} = policy) do
    %{
      enabled: policy.enabled,
      sample_rate: policy.sample_rate,
      redact_keys: policy.redact_keys,
      omit_keys: policy.omit_keys,
      metadata: Value.project(policy.metadata)
    }
  end

  def project(%Jidoka.Eval.Case{} = eval_case) do
    %{
      id: eval_case.id,
      agent: project(eval_case.agent),
      request: project(eval_case.request),
      assertions: Value.project(eval_case.assertions),
      metadata: Value.project(eval_case.metadata)
    }
  end

  def project(%Jidoka.Eval.Run{} = run) do
    %{
      case_id: run.case_id,
      status: run.status,
      result: project(run.result),
      error: Value.project(run.error),
      assertions: Value.project(run.assertions),
      observations: Value.project(run.observations),
      metadata: Value.project(run.metadata)
    }
  end

  def project(%Review.Interrupt{} = interrupt) do
    %{
      id: interrupt.id,
      boundary: interrupt.boundary,
      control: interrupt.control_name,
      reason: Value.project(interrupt.reason),
      agent_id: interrupt.agent_id,
      request_id: interrupt.request_id,
      loop_index: interrupt.loop_index,
      effect_id: interrupt.effect_id,
      effect_kind: interrupt.effect_kind,
      operation: interrupt.operation,
      operation_kind: interrupt.operation_kind,
      arguments: Value.project(interrupt.arguments),
      idempotency: interrupt.idempotency,
      idempotency_key: interrupt.idempotency_key,
      created_at_ms: interrupt.created_at_ms,
      expires_at_ms: interrupt.expires_at_ms,
      metadata: Value.project(interrupt.metadata)
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
      arguments: Value.project(request.arguments),
      reason: Value.project(request.reason),
      created_at_ms: request.created_at_ms,
      expires_at_ms: request.expires_at_ms,
      metadata: Value.project(request.metadata)
    }
  end

  def project(%Review.Response{} = response) do
    %{
      interrupt_id: response.interrupt_id,
      decision: response.decision,
      reason: Value.project(response.reason),
      responded_at_ms: response.responded_at_ms,
      metadata: Value.project(response.metadata)
    }
  end

  def project(%Event{} = event), do: Event.to_map(event)

  def project(value), do: Value.project(value)
end
