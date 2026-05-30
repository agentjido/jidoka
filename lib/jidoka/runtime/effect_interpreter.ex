defmodule Jidoka.Runtime.EffectInterpreter do
  @moduledoc """
  Effect shell for the functional core.

  The interpreter records an intent before calling a runtime capability and
  never calls that capability when the journal already has a result for the same
  effect id.
  """

  alias Jidoka.Error
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Effect
  alias Jidoka.Turn

  @spec interpret_pending(Turn.State.t(), Capabilities.t()) ::
          {:ok, Effect.Result.t(), Turn.State.t()} | {:error, term()}
  def interpret_pending(%Turn.State{} = state, %Capabilities{} = capabilities) do
    case Turn.State.current_pending_effect(state) do
      %Effect.Intent{} = intent ->
        interpret_intent(state, intent, capabilities)

      nil ->
        {:error,
         Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
    end
  end

  def interpret_pending(_state, _capabilities) do
    {:error,
     Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
  end

  defp interpret_intent(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities
       ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        {:ok, result, append_effect_trace(state, intent, :effect_replayed)}

      nil ->
        journal = Effect.Journal.put_intent(state.journal, intent)
        state = %Turn.State{state | journal: journal}
        state = append_effect_trace(state, intent, :effect_started)
        state = append_effect_trace(state, intent, :capability_call_started)

        with {:ok, result} <- call_capability(intent, capabilities, journal) do
          journal = Effect.Journal.put_result(journal, result)
          state = %Turn.State{state | journal: journal}
          state = append_capability_result_trace(state, intent, result)
          state = append_effect_result_trace(state, intent, result)

          {:ok, result, state}
        end
    end
  end

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

  defp append_capability_result_trace(%Turn.State{} = state, %Effect.Intent{} = intent, result) do
    event =
      case result.status do
        :ok -> :capability_call_completed
        :error -> :capability_call_failed
      end

    append_effect_trace(state, intent, event, error: result_error(result))
  end

  defp append_effect_result_trace(%Turn.State{} = state, %Effect.Intent{} = intent, result) do
    event =
      case result.status do
        :ok -> :effect_completed
        :error -> :effect_failed
      end

    append_effect_trace(state, intent, event, error: result_error(result))
  end

  defp append_effect_trace(%Turn.State{} = state, %Effect.Intent{} = intent, event, attrs \\ []) do
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

    state
  end

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
