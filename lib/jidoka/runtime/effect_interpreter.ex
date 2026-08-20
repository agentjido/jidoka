defmodule Jidoka.Runtime.EffectInterpreter do
  @moduledoc """
  Effect shell for the functional core.

  The interpreter records an intent before calling a runtime capability and
  never calls that capability when the journal already has a result for the same
  effect id.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.ModelPolicy
  alias Jidoka.Operation.Continuation
  alias Jidoka.Policy.Gate
  alias Jidoka.Review.Interrupt
  alias Jidoka.Runtime.CapabilityInvoker
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Context, as: RuntimeContext
  alias Jidoka.Runtime.Controls
  alias Jidoka.Runtime.DurableCheckpoint
  alias Jidoka.Runtime.EffectTrace
  alias Jidoka.Runtime.Limits
  alias Jidoka.Runtime.OperationBatchCoordinator
  alias Jidoka.Runtime.OperationInvoker
  alias Jidoka.Runtime.Review
  alias Jidoka.Turn

  @doc "Interprets the next pending effect or reuses its journaled result."
  @spec interpret_pending(Turn.State.t(), Capabilities.t(), keyword()) ::
          {:ok, Effect.Result.t(), Turn.State.t()}
          | {:hibernate, [Continuation.t()], Turn.State.t()}
          | {:interrupt, Interrupt.t(), Turn.State.t()}
          | {:error, term()}
  def interpret_pending(state, capabilities, opts \\ [])

  def interpret_pending(%Turn.State{} = state, %Capabilities{} = capabilities, opts) do
    case Turn.State.current_pending_effect(state) do
      %Effect.Intent{} = intent ->
        interpret_intent(state, intent, capabilities, opts)

      nil ->
        {:error, Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
    end
  end

  def interpret_pending(_state, _capabilities, _opts) do
    {:error, Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
  end

  @doc "Interprets the pending operation effects as a bounded batch."
  @spec interpret_operation_batch(Turn.State.t(), Capabilities.t(), keyword()) ::
          {:ok, [Effect.Result.t()], Turn.State.t()}
          | {:hibernate, [Continuation.t()], Turn.State.t()}
          | {:interrupt, Interrupt.t(), Turn.State.t()}
          | {:error, term()}
  def interpret_operation_batch(%Turn.State{} = state, %Capabilities{} = capabilities, opts \\ []) do
    case current_operation_batch(state) do
      [_one] ->
        case interpret_pending(state, capabilities, opts) do
          {:ok, %Effect.Result{} = result, %Turn.State{} = state} -> {:ok, [result], state}
          other -> other
        end

      intents when length(intents) > 1 ->
        run_operation_batch(state, intents, capabilities, opts)

      [] ->
        {:error, Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
    end
  end

  defp interpret_intent(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         opts
       ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        {:ok, result, EffectTrace.append(state, intent, :effect_replayed, [], opts)}

      nil ->
        with {:ok, %Turn.State{} = state} <- reserve_operation_intent(state, intent),
             :ok <- validate_incomplete_effect_replay(state, intent, opts) do
          journal = Effect.Journal.put_intent(state.journal, intent)
          state = %Turn.State{state | journal: journal}
          state = EffectTrace.append(state, intent, :effect_started, [], opts)

          interpret_after_controls(state, intent, capabilities, journal, opts)
        end
    end
  end

  defp validate_incomplete_effect_replay(
         %Turn.State{journal: journal} = state,
         %Effect.Intent{idempotency: :unsafe_once} = intent,
         opts
       ) do
    cond do
      resumable_operation_continuation?(state, intent, opts) ->
        :ok

      Review.resumable_approval?(intent) ->
        :ok

      Effect.Journal.incomplete_intent?(journal, intent) ->
        {:error,
         Error.normalize({:unsafe_once_incomplete_effect, intent},
           operation: EffectTrace.operation(intent),
           phase: :effect,
           intent_id: intent.id,
           effect_kind: intent.kind
         )}

      true ->
        :ok
    end
  end

  defp validate_incomplete_effect_replay(
         %Turn.State{journal: journal} = state,
         %Effect.Intent{idempotency: idempotency} = intent,
         opts
       )
       when idempotency in [:dedupe, :reconcile] do
    if Effect.Journal.incomplete_intent?(journal, intent) and
         not resumable_operation_continuation?(state, intent, opts) do
      {:error,
       Error.normalize({:effect_reconciliation_required, intent},
         operation: EffectTrace.operation(intent),
         phase: :effect,
         intent_id: intent.id,
         effect_kind: intent.kind
       )}
    else
      :ok
    end
  end

  defp validate_incomplete_effect_replay(_state, _intent, _opts), do: :ok

  defp interpret_after_controls(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         %Effect.Journal{} = _journal,
         opts
       ) do
    case run_effect_controls(state, intent, capabilities, opts) do
      {:ok, %Turn.State{} = state} ->
        execute_controlled_effect(state, intent, capabilities, state.journal, opts)

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        {:interrupt, interrupt, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_controlled_effect(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         %Effect.Journal{} = journal,
         opts
       ) do
    state = EffectTrace.append(state, intent, :capability_call_started, [], opts)

    with :ok <- DurableCheckpoint.persist(state, intent, :intent, opts) do
      execute_persisted_effect(state, intent, capabilities, journal, opts)
    end
  end

  defp execute_persisted_effect(state, intent, capabilities, journal, opts) do
    case call_capability(state, intent, capabilities, journal, opts) do
      {:ok, %Effect.Result{} = result} ->
        finalize_effect_result(state, intent, result, journal, opts)

      {:hibernate, %Continuation{} = continuation} ->
        {:hibernate, [continuation], state}
    end
  end

  defp finalize_effect_result(state, intent, result, journal, opts) do
    case checkpoint_effect_result(state, intent, result, journal, opts) do
      {:ok, state} -> {:ok, result, state}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_effect_result(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Effect.Result{} = result,
         %Effect.Journal{} = journal,
         opts
       ) do
    case Limits.record_effect_result(state, result) do
      {:ok, state} ->
        persist_effect_result(state, intent, result, journal, opts)

      {:error, reason, state} ->
        with {:ok, _state} <- persist_effect_result(state, intent, result, journal, opts) do
          {:error, reason}
        end
    end
  end

  defp persist_effect_result(%Turn.State{} = state, intent, result, journal, opts) do
    journal = Effect.Journal.put_result(journal, result)

    state =
      %Turn.State{state | journal: journal}
      |> EffectTrace.append_capability_result(intent, result, opts)
      |> EffectTrace.append_effect_result(intent, result, opts)

    with :ok <- DurableCheckpoint.persist(state, intent, :result, opts), do: {:ok, state}
  end

  defp reserve_operation_intent(%Turn.State{} = state, %Effect.Intent{kind: :operation} = intent),
    do: Limits.reserve_operation_group(state, [intent])

  defp reserve_operation_intent(%Turn.State{} = state, %Effect.Intent{}), do: {:ok, state}

  defp run_effect_controls(
         %Turn.State{} = state,
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{} = capabilities,
         opts
       ) do
    event_count = length(state.events)

    case Controls.run_operation_controls(state, intent, opts) do
      {:ok, %Turn.State{} = state} ->
        EffectTrace.emit_events(Enum.drop(state.events, event_count), opts)
        run_policy_gate(state, intent, capabilities, opts)

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        EffectTrace.emit_events(Enum.drop(state.events, event_count), opts)
        {:interrupt, interrupt, state}

      {:error, reason} ->
        {:error,
         Error.normalize(reason,
           operation: EffectTrace.operation(intent),
           phase: :control,
           agent_id: state.plan.spec.id,
           request_id: EffectTrace.request_id(state, intent),
           intent_id: intent.id,
           effect_kind: intent.kind
         )}
    end
  end

  defp run_effect_controls(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         opts
       ),
       do: run_policy_gate(state, intent, capabilities, opts)

  defp run_policy_gate(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{policy: policy},
         opts
       ) do
    case Gate.authorize(state, intent, policy, opts) do
      {:allow, _decision, %Turn.State{} = state} ->
        {:ok, state}

      {:deny, decision, %Turn.State{}} ->
        {:error,
         Error.normalize({:policy_denied, decision.rule_id, decision.reason},
           operation: EffectTrace.operation(intent) || intent.kind,
           phase: :control,
           agent_id: state.plan.spec.id,
           request_id: EffectTrace.request_id(state, intent),
           intent_id: intent.id,
           effect_kind: intent.kind
         )}

      {:review, _decision, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        {:interrupt, interrupt, state}

      {:error, reason} ->
        {:error,
         Error.normalize(reason,
           operation: EffectTrace.operation(intent) || intent.kind,
           phase: :control,
           agent_id: state.plan.spec.id,
           request_id: EffectTrace.request_id(state, intent),
           intent_id: intent.id,
           effect_kind: intent.kind
         )}
    end
  end

  defp call_capability(
         %Turn.State{} = state,
         %Effect.Intent{kind: :llm} = intent,
         %Capabilities{llm: llm},
         journal,
         opts
       ) do
    ctx = RuntimeContext.llm!(state, runtime: RuntimeContext.runtime(state, opts, :llm_context))

    case invoke_capability(llm, intent, journal, ctx, state, opts) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output, metadata: output_metadata(output))}

      {:error, reason} ->
        {:ok,
         Effect.Result.error(intent, normalize_capability_error(reason, intent),
           metadata: ModelPolicy.error_metadata(reason)
         )}

      other ->
        {:ok,
         Effect.Result.error(
           intent,
           normalize_capability_error({:invalid_capability_result, other}, intent)
         )}
    end
  end

  defp call_capability(
         %Turn.State{} = state,
         %Effect.Intent{kind: :operation} = intent,
         %Capabilities{} = capabilities,
         journal,
         opts
       ) do
    OperationInvoker.invoke(state, intent, capabilities, journal, opts)
  end

  defp invoke_capability(capability, intent, journal, ctx, state, opts),
    do: CapabilityInvoker.invoke(capability, intent, journal, ctx, state, opts)

  defp normalize_capability_error(reason, %Effect.Intent{} = intent) do
    Error.normalize(reason,
      operation: intent.kind,
      phase: :effect,
      intent_id: intent.id,
      effect_kind: intent.kind
    )
  end

  defp output_metadata(%Effect.LLMDecision{metadata: metadata}) when is_map(metadata), do: metadata
  defp output_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp output_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp output_metadata(_output), do: %{}

  defp current_operation_batch(%Turn.State{pending_effects: effects}) do
    Enum.take_while(effects, &match?(%Effect.Intent{kind: :operation}, &1))
  end

  defp run_operation_batch(
         %Turn.State{} = state,
         intents,
         %Capabilities{} = capabilities,
         opts
       ) do
    OperationBatchCoordinator.run(
      state,
      intents,
      capabilities,
      opts,
      &preflight_operation_intent/4
    )
  end

  defp preflight_operation_intent(
         %Turn.State{} = state,
         %Effect.Intent{} = intent,
         %Capabilities{} = capabilities,
         opts
       ) do
    with :ok <- validate_incomplete_effect_replay(state, intent, opts) do
      state = EffectTrace.append(state, intent, :effect_started, [], opts)

      case run_effect_controls(state, intent, capabilities, opts) do
        {:ok, %Turn.State{} = state} ->
          {:ok, state, intent}

        {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
          {:interrupt, interrupt, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resumable_operation_continuation?(state, intent, opts) do
    with {kind, source} <- operation_continuation_route(state, intent),
         {:ok, continuations} <-
           opts
           |> Keyword.get(:operation_context, %{})
           |> operation_continuations()
           |> Continuation.list_from_input() do
      Continuation.resumes_intent?(continuations, intent, kind, source)
    else
      _missing_or_invalid -> false
    end
  end

  defp operation_continuation_route(%Turn.State{plan: %{spec: %{operations: operations}}}, intent) do
    name = EffectTrace.operation(intent)

    case Enum.find(operations, &(&1.name == name)) do
      %Operation{} = operation ->
        case Operation.kind(operation) do
          kind when kind in [:workflow, :subagent] -> {kind, name}
          _kind -> nil
        end

      nil ->
        nil
    end
  end

  defp operation_continuations(context) when is_list(context) do
    if Keyword.keyword?(context) do
      Keyword.get(context, :operation_continuations, [])
    else
      []
    end
  end

  defp operation_continuations(%Jidoka.Context{} = context) do
    Jidoka.Context.get_runtime(context, :operation_continuations, [])
  end

  defp operation_continuations(context) when is_map(context) do
    Map.get(context, :operation_continuations, Map.get(context, "operation_continuations", []))
  end

  defp operation_continuations(_context), do: []
end
