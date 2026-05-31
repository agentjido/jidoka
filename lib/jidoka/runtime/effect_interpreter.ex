defmodule Jidoka.Runtime.EffectInterpreter do
  @moduledoc """
  Effect shell for the functional core.

  The interpreter records an intent before calling a runtime capability and
  never calls that capability when the journal already has a result for the same
  effect id.
  """

  alias Jidoka.Error
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Controls
  alias Jidoka.Stream, as: EventStream
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
  alias Jidoka.Turn

  @spec interpret_pending(Turn.State.t(), Capabilities.t(), keyword()) ::
          {:ok, Effect.Result.t(), Turn.State.t()}
          | {:interrupt, Interrupt.t(), Turn.State.t()}
          | {:error, term()}
  def interpret_pending(state, capabilities, opts \\ [])

  def interpret_pending(%Turn.State{} = state, %Capabilities{} = capabilities, opts) do
    case Turn.State.current_pending_effect(state) do
      %Effect.Intent{} = intent ->
        interpret_intent(state, intent, capabilities, opts)

      nil ->
        {:error,
         Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
    end
  end

  def interpret_pending(_state, _capabilities, _opts) do
    {:error,
     Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
  end

  defp interpret_intent(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         opts
       ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        {:ok, result, append_effect_trace(state, intent, :effect_replayed, [], opts)}

      nil ->
        with :ok <- validate_incomplete_effect_replay(state, intent) do
          journal = Effect.Journal.put_intent(state.journal, intent)
          state = %Turn.State{state | journal: journal}
          state = append_effect_trace(state, intent, :effect_started, [], opts)

          interpret_after_controls(state, intent, capabilities, journal, opts)
        end
    end
  end

  defp validate_incomplete_effect_replay(
         %Turn.State{journal: journal},
         %Effect.Intent{idempotency: :unsafe_once} = intent
       ) do
    cond do
      approved_interrupt_id(intent) ->
        :ok

      Effect.Journal.incomplete_intent?(journal, intent) ->
        {:error,
         Error.normalize({:unsafe_once_incomplete_effect, intent},
           operation: effect_operation(intent),
           phase: :effect,
           intent_id: intent.id,
           effect_kind: intent.kind
         )}

      true ->
        :ok
    end
  end

  defp validate_incomplete_effect_replay(_state, _intent), do: :ok

  defp approved_interrupt_id(%Effect.Intent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :approved_interrupt_id) || Map.get(metadata, "approved_interrupt_id")
  end

  defp interpret_after_controls(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         %Effect.Journal{} = journal,
         opts
       ) do
    case run_effect_controls(state, intent, opts) do
      {:ok, %Turn.State{} = state} ->
        state = append_effect_trace(state, intent, :capability_call_started, [], opts)

        with {:ok, result} <- call_capability(intent, capabilities, journal) do
          journal = Effect.Journal.put_result(journal, result)
          state = %Turn.State{state | journal: journal}
          state = append_capability_result_trace(state, intent, result, opts)
          state = append_effect_result_trace(state, intent, result, opts)

          {:ok, result, state}
        end

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        {:interrupt, interrupt, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_effect_controls(
         %Turn.State{} = state,
         %Effect.Intent{kind: :operation} = intent,
         opts
       ) do
    event_count = length(state.events)

    case Controls.run_operation_controls(state, intent) do
      {:ok, %Turn.State{} = state} ->
        emit_events(Enum.drop(state.events, event_count), opts)
        {:ok, state}

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        emit_events(Enum.drop(state.events, event_count), opts)
        {:interrupt, interrupt, state}

      {:error, reason} ->
        {:error,
         Error.normalize(reason,
           operation: effect_operation(intent),
           phase: :control,
           agent_id: state.spec.id,
           request_id: effect_request_id(state, intent),
           intent_id: intent.id,
           effect_kind: intent.kind
         )}
    end
  end

  defp run_effect_controls(%Turn.State{} = state, %Effect.Intent{}, _opts), do: {:ok, state}

  defp call_capability(%Effect.Intent{kind: :llm} = intent, %Capabilities{llm: llm}, journal) do
    case invoke_capability(llm, intent, journal) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output)}

      {:error, reason} ->
        {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}

      other ->
        {:ok,
         Effect.Result.error(
           intent,
           normalize_capability_error({:invalid_capability_result, other}, intent)
         )}
    end
  end

  defp call_capability(
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{operations: operations},
         journal
       ) do
    case invoke_capability(operations, intent, journal) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output)}

      {:error, reason} ->
        {:ok, Effect.Result.error(intent, normalize_capability_error(reason, intent))}

      other ->
        {:ok,
         Effect.Result.error(
           intent,
           normalize_capability_error({:invalid_capability_result, other}, intent)
         )}
    end
  end

  defp invoke_capability(capability, intent, journal) do
    capability.(intent, journal)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_capability_error(reason, %Effect.Intent{} = intent) do
    Error.normalize(reason,
      operation: intent.kind,
      phase: :effect,
      intent_id: intent.id,
      effect_kind: intent.kind
    )
  end

  defp append_capability_result_trace(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         result,
         opts
       ) do
    event =
      case result.status do
        :ok -> :capability_call_completed
        :error -> :capability_call_failed
      end

    append_effect_trace(state, intent, event, [error: result_error(result)], opts)
  end

  defp append_effect_result_trace(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         result,
         opts
       ) do
    event =
      case result.status do
        :ok -> :effect_completed
        :error -> :effect_failed
      end

    append_effect_trace(state, intent, event, [error: result_error(result)], opts)
  end

  defp append_effect_trace(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         event,
         attrs,
         opts
       ) do
    trace_attrs =
      [
        agent_id: state.spec.id,
        request_id: effect_request_id(state, intent),
        loop_index: effect_loop_index(state, intent),
        effect_id: intent.id,
        effect_kind: intent.kind,
        operation: effect_operation(intent),
        data: %{
          idempotency: intent.idempotency,
          idempotency_key: intent.idempotency_key
        }
      ]
      |> Keyword.merge(attrs)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    %Turn.State{} =
      state =
      state
      |> Turn.Transition.new!()
      |> Turn.Transition.event(event, trace_attrs)
      |> Turn.Transition.commit()

    state.events
    |> List.last()
    |> then(&EventStream.emit(&1, opts))

    state
  end

  defp emit_events(events, opts), do: EventStream.emit_events(events, opts)

  defp effect_request_id(%Turn.State{} = state, %Effect.Intent{} = intent) do
    Map.get(intent.payload, :request_id) ||
      Map.get(intent.payload, "request_id") ||
      state.request.request_id
  end

  defp effect_loop_index(%Turn.State{} = state, %Effect.Intent{} = intent) do
    Map.get(intent.payload, :loop_index) ||
      Map.get(intent.payload, "loop_index") ||
      state.loop_index
  end

  defp effect_operation(%Effect.Intent{kind: :operation, payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end

  defp effect_operation(_intent), do: nil

  defp result_error(%Effect.Result{status: :error, output: output}), do: Error.to_map(output)
  defp result_error(_result), do: nil
end
