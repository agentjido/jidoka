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
      results: Enum.map(controls.results, &project/1),
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

  def project(%Agent.Spec.Controls.Result{} = result) do
    %{
      control: control_name(result.control),
      module: inspect(result.control),
      metadata: project_value(result.metadata)
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
      prompt: project_value(state.prompt),
      llm_result: project_value(state.llm_result),
      operation_plan: project_value(state.operation_plan),
      pending_effects: Enum.map(state.pending_effects, &project/1),
      result: state.result,
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
