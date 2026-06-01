defmodule Jidoka.Runtime.Controls.Operation do
  @moduledoc """
  Runtime evaluator for operation-scoped controls.
  """

  alias Jidoka.Agent.Spec.Controls.Operation, as: OperationControl
  alias Jidoka.Agent.Spec.Operation, as: OperationSpec
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
  alias Jidoka.Runtime.Controls.Decision
  alias Jidoka.Runtime.Controls.OperationContext
  alias Jidoka.Turn

  @spec run(Turn.State.t(), Effect.Intent.t()) ::
          {:ok, Turn.State.t()} | {:interrupt, Interrupt.t(), Turn.State.t()} | {:error, term()}
  def run(%Turn.State{} = state, %Effect.Intent{kind: :operation} = intent) do
    if approved_interrupt_id(intent) do
      {:ok, append_approval_reused_event(state, intent)}
    else
      run_unapproved(state, intent)
    end
  end

  def run(%Turn.State{} = state, %Effect.Intent{}), do: {:ok, state}

  defp run_unapproved(%Turn.State{} = state, %Effect.Intent{kind: :operation} = intent) do
    with {:ok, request} <- Effect.OperationRequest.from_input(intent.payload) do
      operation = operation_for(state, request.name)
      operation_kind = operation_kind(operation, request)
      operation_match = operation_match_data(operation, request, operation_kind, intent)

      controls =
        Enum.filter(
          state.spec.controls.operations,
          &OperationControl.matches?(&1, operation_match)
        )

      run_controls(state, controls, request, operation, operation_match, intent)
    end
  end

  defp run_controls(
         %Turn.State{} = state,
         controls,
         %Effect.OperationRequest{} = request,
         operation,
         operation_match,
         %Effect.Intent{} = intent
       )
       when is_list(controls) do
    Enum.reduce_while(controls, {:ok, state}, fn control, {:ok, state} ->
      case call_control(control, state, request, operation, operation_match, intent)
           |> Decision.normalize() do
        :allow ->
          {:cont, {:ok, append_control_event(state, control, request, operation_match)}}

        {:block, reason} ->
          {:halt, {:error, {:control_blocked, control.control, :operation, reason}}}

        {:interrupt, reason} ->
          interrupt =
            operation_interrupt(control, state, request, operation_match, intent, reason)

          state =
            append_control_event(state, control, request, operation_match, interrupt)

          {:halt, {:interrupt, interrupt, state}}

        {:error, reason} ->
          {:halt, {:error, {:control_failed, control.control, :operation, reason}}}

        {:invalid, decision} ->
          {:halt, {:error, {:invalid_control_decision, control.control, :operation, decision}}}
      end
    end)
  end

  defp call_control(
         %OperationControl{} = control,
         %Turn.State{} = state,
         %Effect.OperationRequest{} = request,
         operation,
         operation_match,
         %Effect.Intent{} = intent
       ) do
    control.control.call(
      OperationContext.new!(
        type: :control,
        boundary: :operation,
        control: control.control,
        control_name: control_name(control.control),
        metadata: control.metadata,
        request_metadata: state.request.metadata,
        operation: request.name,
        kind: operation_match.kind,
        operation_kind: operation_match.kind,
        source: operation_match.source,
        arguments: request.arguments,
        operation_match: control.match,
        operation_metadata: operation_match.metadata,
        idempotency: intent.idempotency,
        idempotency_key: intent.idempotency_key,
        spec: state.spec,
        plan: state.plan,
        request: state.request,
        input: state.request.input,
        context: state.request.context,
        agent_state: state.agent_state,
        intent: intent,
        operation_request: request,
        operation_spec: operation
      )
    )
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp append_control_event(
         %Turn.State{} = state,
         %OperationControl{} = control,
         %Effect.OperationRequest{} = request,
         operation_match,
         interrupt \\ nil
       ) do
    state
    |> Turn.Transition.new!()
    |> Turn.Transition.event(control_event(interrupt),
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      operation: request.name,
      data:
        %{
          boundary: :operation,
          control: control_name(control.control),
          operation: request.name,
          operation_kind: operation_match.kind,
          source: operation_match.source,
          interrupt_id: interrupt_id(interrupt)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    )
    |> Turn.Transition.commit()
  end

  defp append_approval_reused_event(%Turn.State{} = state, %Effect.Intent{} = intent) do
    case Effect.OperationRequest.from_input(intent.payload) do
      {:ok, request} ->
        state
        |> Turn.Transition.new!()
        |> Turn.Transition.event(:approval_applied,
          agent_id: state.spec.id,
          request_id: request.request_id || state.request.request_id,
          loop_index: request.loop_index,
          effect_id: intent.id,
          effect_kind: intent.kind,
          operation: request.name,
          data: %{
            interrupt_id: approved_interrupt_id(intent),
            operation: request.name
          }
        )
        |> Turn.Transition.commit()

      {:error, _reason} ->
        state
    end
  end

  defp operation_interrupt(
         %OperationControl{} = control,
         %Turn.State{} = state,
         %Effect.OperationRequest{} = request,
         operation_match,
         %Effect.Intent{} = intent,
         reason
       ) do
    Interrupt.new!(
      id:
        Interrupt.stable_id([
          state.spec.id,
          state.request.request_id,
          intent.id,
          control.control,
          request.name
        ]),
      boundary: :operation,
      control: control.control,
      control_name: control_name(control.control),
      reason: reason,
      agent_id: state.spec.id,
      request_id: state.request.request_id,
      loop_index: state.loop_index,
      effect_id: intent.id,
      effect_kind: intent.kind,
      operation: request.name,
      operation_kind: operation_match.kind,
      arguments: request.arguments,
      idempotency: intent.idempotency,
      idempotency_key: intent.idempotency_key,
      metadata: %{
        "operation_match" => control.match,
        "control_metadata" => control.metadata
      }
    )
  end

  defp control_event(nil), do: :control_allowed
  defp control_event(%Interrupt{}), do: :control_interrupted

  defp interrupt_id(nil), do: nil
  defp interrupt_id(%Interrupt{id: id}), do: id

  defp operation_for(%Turn.State{spec: %{operations: operations}}, name) do
    Enum.find(operations, &(&1.name == name))
  end

  defp operation_kind(%OperationSpec{} = operation, _request), do: OperationSpec.kind(operation)

  defp operation_kind(nil, %Effect.OperationRequest{metadata: metadata}) do
    kind_from_metadata(metadata) || :operation
  end

  defp operation_match_data(
         operation,
         %Effect.OperationRequest{} = request,
         operation_kind,
         intent
       ) do
    metadata = operation_metadata(operation, request)

    %{
      name: request.name,
      kind: operation_kind,
      source: source_from_metadata(metadata),
      idempotency: operation_idempotency(operation, intent),
      metadata: metadata
    }
  end

  defp operation_metadata(%OperationSpec{metadata: metadata}, _request) when is_map(metadata),
    do: metadata

  defp operation_metadata(_operation, %Effect.OperationRequest{metadata: metadata})
       when is_map(metadata),
       do: metadata

  defp operation_idempotency(%OperationSpec{idempotency: idempotency}, _intent), do: idempotency

  defp operation_idempotency(_operation, %Effect.Intent{idempotency: idempotency}),
    do: idempotency

  defp source_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> get_any([:source, "source", :runtime, "runtime"])
    |> normalize_source()
  end

  defp kind_from_metadata(metadata) do
    metadata_kind(metadata) || runtime_kind(metadata)
  end

  defp metadata_kind(metadata) do
    metadata
    |> get_any([:kind, "kind", :operation_kind, "operation_kind", :source_kind, "source_kind"])
    |> normalize_kind()
  end

  defp runtime_kind(metadata) do
    case get_any(metadata, [:runtime, "runtime", :source, "source"]) do
      value when value in [:jido_action, "jido_action"] -> :action
      _value -> nil
    end
  end

  defp normalize_kind(kind) when is_atom(kind) do
    if kind in OperationControl.valid_kinds(), do: kind
  end

  defp normalize_kind(kind) when is_binary(kind) do
    normalized = kind |> String.trim() |> String.downcase()

    Enum.find(OperationControl.valid_kinds(), &(Atom.to_string(&1) == normalized))
  end

  defp normalize_kind(_kind), do: nil

  defp normalize_source(source) when is_atom(source) and not is_nil(source),
    do: Atom.to_string(source)

  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(_source), do: nil

  defp approved_interrupt_id(%Effect.Intent{metadata: metadata}) when is_map(metadata) do
    get_any(metadata, [:approved_interrupt_id, "approved_interrupt_id"])
  end

  defp approved_interrupt_id(_intent), do: nil

  defp get_any(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp control_name(control) do
    case Jidoka.Control.control_name(control) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(control)
    end
  end
end
