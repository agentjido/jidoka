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
  alias Jidoka.Error
  alias Jidoka.Harness
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc "Projects a supported Jidoka data contract into a stable map."
  @spec project(term()) :: term()
  def project(%Agent.Spec{} = spec) do
    %{
      id: spec.id,
      instructions: spec.instructions,
      model: Jidoka.Config.model_ref(spec.model),
      generation: project(spec.generation),
      context_schema?: not is_nil(spec.context_schema),
      result: project(spec.result),
      memory: project(spec.memory),
      operations: Enum.map(spec.operations, &project/1),
      controls: project(spec.controls),
      runtime_defaults: project_value(spec.runtime_defaults),
      metadata: project_agent_metadata(spec.metadata)
    }
  end

  def project(%Agent.Spec.Generation{} = generation) do
    %{
      params: project_value(generation.params),
      provider_options: project_value(generation.provider_options),
      extra: project_value(generation.extra)
    }
  end

  def project(%Agent.Spec.Result{} = result) do
    %{
      schema?: not is_nil(result.schema),
      max_repairs: result.max_repairs,
      metadata: project_value(result.metadata)
    }
  end

  def project(%Agent.Spec.Memory{} = memory) do
    %{
      enabled: memory.enabled,
      scope: memory.scope,
      max_entries: memory.max_entries,
      metadata: project_value(memory.metadata)
    }
  end

  def project(%Agent.Spec.Operation{} = operation) do
    %{
      name: operation.name,
      description: operation.description,
      idempotency: operation.idempotency,
      metadata: project_operation_metadata(operation.metadata)
    }
  end

  def project(%Agent.Spec.Controls{} = controls) do
    %{
      max_turns: controls.max_turns,
      timeout_ms: controls.timeout_ms,
      inputs: Enum.map(controls.inputs, &project/1),
      operations: Enum.map(controls.operations, &project/1),
      outputs: Enum.map(controls.outputs, &project/1),
      metadata: project_value(controls.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Input{} = input) do
    %{
      control: control_name(input.control),
      module: inspect(input.control),
      metadata: project_value(input.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Output{} = output) do
    %{
      control: control_name(output.control),
      module: inspect(output.control),
      metadata: project_value(output.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Operation{} = operation_control) do
    %{
      control: control_name(operation_control.control),
      module: inspect(operation_control.control),
      match: project_value(operation_control.match),
      metadata: project_value(operation_control.metadata)
    }
  end

  def project(%Turn.Plan{} = plan) do
    %{
      spec_id: plan.spec.id,
      workflow_profile: plan.workflow_profile,
      max_model_turns: plan.max_model_turns,
      timeout_ms: plan.timeout_ms,
      phases: plan.phases,
      metadata: project_value(plan.metadata)
    }
  end

  def project(%Turn.Request{} = request) do
    %{
      request_id: request.request_id,
      input: request.input,
      context: project_value(request.context),
      metadata: project_value(request.metadata),
      agent_state: project(request.agent_state)
    }
  end

  def project(%Agent.State{} = state) do
    %{
      messages: Enum.map(state.messages, &project/1),
      operation_results: Enum.map(state.operation_results, &project/1),
      metadata: project_value(state.metadata)
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
      compactions: Enum.map(state.compactions, &project/1),
      prompt: project_value(state.prompt),
      llm_result: project_value(state.llm_result),
      operation_plan: project_value(state.operation_plan),
      pending_effects: Enum.map(state.pending_effects, &project/1),
      pending_interrupt: project(state.pending_interrupt),
      result: state.result,
      result_value: project_value(state.result_value),
      result_repair_count: state.result_repair_count,
      status: state.status,
      loop_index: state.loop_index,
      started_at_ms: state.started_at_ms,
      journal: project(state.journal),
      events: project_value(state.events),
      diagnostics: project_value(state.diagnostics)
    }
  end

  def project(%Turn.Cursor{} = cursor) do
    %{
      phase: cursor.phase,
      loop_index: cursor.loop_index,
      metadata: project_value(cursor.metadata)
    }
  end

  def project(%Turn.Result{} = result) do
    %{
      content: result.content,
      value: project_value(result.value),
      agent_state: project(result.agent_state),
      journal: project(result.journal),
      events: project_value(result.events),
      metadata: project_value(result.metadata)
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
      payload: project_value(intent.payload),
      idempotency_key: intent.idempotency_key,
      idempotency: intent.idempotency,
      metadata: project_value(intent.metadata)
    }
  end

  def project(%Effect.LLMDecision{} = decision) do
    decision
    |> Effect.LLMDecision.to_payload()
    |> Map.put(:metadata, project_value(decision.metadata))
  end

  def project(%Effect.OperationRequest{} = request) do
    request
    |> Effect.OperationRequest.to_payload()
    |> project_value()
  end

  def project(%Effect.OperationResult{} = result) do
    %{
      operation: result.operation,
      arguments: project_value(result.arguments),
      output: project_value(result.output),
      content: result.content,
      request_id: result.request_id,
      loop_index: result.loop_index,
      effect_id: result.effect_id,
      metadata: project_value(result.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Effect.Result{} = result) do
    %{
      intent_id: result.intent_id,
      kind: result.kind,
      status: result.status,
      output: project_value(result.output),
      metadata: project_value(result.metadata)
    }
  end

  def project(%Jidoka.Memory.Entry{} = entry) do
    %{
      id: entry.id,
      agent_id: entry.agent_id,
      session_id: entry.session_id,
      content: entry.content,
      metadata: project_value(entry.metadata)
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
      metadata: project_value(request.metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def project(%Jidoka.Memory.RecallResult{} = result) do
    %{
      request: project(result.request),
      entries: Enum.map(result.entries, &project/1),
      metadata: project_value(result.metadata)
    }
  end

  def project(%Jidoka.Memory.WriteRequest{} = request) do
    %{
      entry: project(request.entry),
      metadata: project_value(request.metadata)
    }
  end

  def project(%Jidoka.Memory.WriteResult{} = result) do
    %{
      request: project(result.request),
      entry: project(result.entry),
      status: result.status,
      metadata: project_value(result.metadata)
    }
  end

  def project(%Jidoka.Memory.Compaction{} = compaction) do
    %{
      id: compaction.id,
      agent_id: compaction.agent_id,
      summary: compaction.summary,
      source_message_ids: compaction.source_message_ids,
      metadata: project_value(compaction.metadata)
    }
  end

  def project(%AgentSnapshot{} = snapshot) do
    %{
      schema_version: snapshot.schema_version,
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: project(snapshot.cursor),
      turn_state: project(snapshot.turn_state),
      metadata: project_value(snapshot.metadata)
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
      error: project_value(session.error),
      metadata: project_value(session.metadata)
    }
  end

  def project(%Harness.Replay{} = replay) do
    replay
    |> Map.from_struct()
    |> project_value()
  end

  def project(%Jidoka.Trace.Policy{} = policy) do
    %{
      enabled: policy.enabled,
      sample_rate: policy.sample_rate,
      redact_keys: policy.redact_keys,
      omit_keys: policy.omit_keys,
      metadata: project_value(policy.metadata)
    }
  end

  def project(%Jidoka.Eval.Case{} = eval_case) do
    %{
      id: eval_case.id,
      agent: project(eval_case.agent),
      request: project(eval_case.request),
      assertions: project_value(eval_case.assertions),
      metadata: project_value(eval_case.metadata)
    }
  end

  def project(%Jidoka.Eval.Run{} = run) do
    %{
      case_id: run.case_id,
      status: run.status,
      result: project(run.result),
      error: project_value(run.error),
      assertions: project_value(run.assertions),
      observations: project_value(run.observations),
      metadata: project_value(run.metadata)
    }
  end

  def project(%Review.Interrupt{} = interrupt) do
    %{
      id: interrupt.id,
      boundary: interrupt.boundary,
      control: interrupt.control_name,
      reason: project_value(interrupt.reason),
      agent_id: interrupt.agent_id,
      request_id: interrupt.request_id,
      loop_index: interrupt.loop_index,
      effect_id: interrupt.effect_id,
      effect_kind: interrupt.effect_kind,
      operation: interrupt.operation,
      operation_kind: interrupt.operation_kind,
      arguments: project_value(interrupt.arguments),
      idempotency: interrupt.idempotency,
      idempotency_key: interrupt.idempotency_key,
      created_at_ms: interrupt.created_at_ms,
      expires_at_ms: interrupt.expires_at_ms,
      metadata: project_value(interrupt.metadata)
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
      arguments: project_value(request.arguments),
      reason: project_value(request.reason),
      created_at_ms: request.created_at_ms,
      expires_at_ms: request.expires_at_ms,
      metadata: project_value(request.metadata)
    }
  end

  def project(%Review.Response{} = response) do
    %{
      interrupt_id: response.interrupt_id,
      decision: response.decision,
      reason: project_value(response.reason),
      responded_at_ms: response.responded_at_ms,
      metadata: project_value(response.metadata)
    }
  end

  def project(%Event{} = event), do: Event.to_map(event)

  def project(value), do: project_value(value)

  defp project_agent_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(["dsl_module", :dsl_module])
    |> project_value()
  end

  defp project_agent_metadata(metadata), do: project_value(metadata)

  defp project_operation_metadata(metadata) when is_map(metadata) do
    has_parameters_schema? =
      is_map(Map.get(metadata, "parameters_schema") || Map.get(metadata, :parameters_schema))

    metadata
    |> Map.drop(["parameters_schema", :parameters_schema])
    |> project_value()
    |> Map.put("parameters_schema?", has_parameters_schema?)
  end

  defp project_operation_metadata(metadata), do: project_value(metadata)

  defp control_name(module) when is_atom(module) do
    case Jidoka.Control.control_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end

  defp project_value(%_{} = exception) when is_exception(exception), do: Error.to_map(exception)

  defp project_value(%LLMDB.Model{} = model), do: Jidoka.Config.model_ref(model)

  defp project_value(%module{} = struct) do
    if zoi_schema?(module) do
      %{schema?: true}
    else
      struct
      |> Map.from_struct()
      |> project_value()
    end
  end

  defp project_value(%{} = map) do
    Map.new(map, fn {key, value} -> {key, project_value(value)} end)
  end

  defp project_value(list) when is_list(list), do: Enum.map(list, &project_value/1)
  defp project_value(value), do: value

  defp zoi_schema?(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Zoi.Types.")
  end
end
