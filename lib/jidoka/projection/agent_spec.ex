defmodule Jidoka.Projection.AgentSpec do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.Projection.{Metadata, Value}

  @spec project(
          Agent.Spec.t()
          | Agent.Spec.Generation.t()
          | Agent.Spec.Result.t()
          | Agent.Spec.Memory.t()
          | Agent.Spec.Operation.t()
          | Agent.Spec.Controls.t()
          | Agent.Spec.Controls.Input.t()
          | Agent.Spec.Controls.Output.t()
          | Agent.Spec.Controls.Operation.t()
          | nil
        ) :: map() | nil
  def project(nil), do: nil

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
      runtime_defaults: Value.project(spec.runtime_defaults),
      metadata: Metadata.agent(spec.metadata)
    }
  end

  def project(%Agent.Spec.Generation{} = generation) do
    %{
      params: Value.project(generation.params),
      provider_options: Value.project(generation.provider_options),
      extra: Value.project(generation.extra)
    }
  end

  def project(%Agent.Spec.Result{} = result) do
    %{
      schema?: not is_nil(result.schema),
      max_repairs: result.max_repairs,
      metadata: Value.project(result.metadata)
    }
  end

  def project(%Agent.Spec.Memory{} = memory) do
    %{
      enabled: memory.enabled,
      scope: memory.scope,
      namespace: Value.project(memory.namespace),
      capture: memory.capture,
      inject: memory.inject,
      max_entries: memory.max_entries,
      metadata: Value.project(memory.metadata)
    }
  end

  def project(%Agent.Spec.Operation{} = operation) do
    %{
      name: operation.name,
      description: operation.description,
      idempotency: operation.idempotency,
      metadata: Metadata.operation(operation.metadata)
    }
  end

  def project(%Agent.Spec.Controls{} = controls) do
    %{
      max_turns: controls.max_turns,
      timeout_ms: controls.timeout_ms,
      inputs: Enum.map(controls.inputs, &project/1),
      operations: Enum.map(controls.operations, &project/1),
      outputs: Enum.map(controls.outputs, &project/1),
      metadata: Value.project(controls.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Input{} = input) do
    %{
      control: Metadata.control_name(input.control),
      module: inspect(input.control),
      metadata: Value.project(input.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Output{} = output) do
    %{
      control: Metadata.control_name(output.control),
      module: inspect(output.control),
      metadata: Value.project(output.metadata)
    }
  end

  def project(%Agent.Spec.Controls.Operation{} = operation_control) do
    %{
      control: Metadata.control_name(operation_control.control),
      module: inspect(operation_control.control),
      match: Value.project(operation_control.match),
      metadata: Value.project(operation_control.metadata)
    }
  end
end
