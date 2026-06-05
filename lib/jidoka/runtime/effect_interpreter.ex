defmodule Jidoka.Runtime.EffectInterpreter do
  @moduledoc """
  Effect shell for the functional core.

  The interpreter records an intent before calling a runtime capability and
  never calls that capability when the journal already has a result for the same
  effect id.
  """

  require Runic

  alias Jidoka.Config
  alias Jidoka.Error
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.Controls
  alias Jidoka.Stream, as: EventStream
  alias Jidoka.Effect
  alias Jidoka.Review.Interrupt
  alias Jidoka.Turn
  alias Runic.Workflow

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
        {:error, Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
    end
  end

  def interpret_pending(_state, _capabilities, _opts) do
    {:error, Error.normalize(:missing_pending_effect, operation: :interpret_effect, phase: :effect)}
  end

  @spec interpret_operation_batch(Turn.State.t(), Capabilities.t(), keyword()) ::
          {:ok, [Effect.Result.t()], Turn.State.t()}
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
         %Effect.Intent{kind: :operation, metadata: metadata} = intent,
         opts
       )
       when is_map(metadata) do
    event_count = length(state.events)

    if operation_controls_allowed?(metadata) do
      {:ok, state}
    else
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
  end

  defp run_effect_controls(%Turn.State{} = state, %Effect.Intent{}, _opts), do: {:ok, state}

  defp operation_controls_allowed?(metadata) when is_map(metadata) do
    metadata["operation_controls_allowed"] == true or metadata[:operation_controls_allowed] == true
  end

  defp call_capability(%Effect.Intent{kind: :llm} = intent, %Capabilities{llm: llm}, journal) do
    case invoke_capability(llm, intent, journal) do
      {:ok, output} ->
        {:ok, Effect.Result.ok(intent, output, metadata: output_metadata(output))}

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

  defp output_metadata(%Effect.LLMDecision{metadata: metadata}) when is_map(metadata), do: metadata
  defp output_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp output_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp output_metadata(_output), do: %{}

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

  defp current_operation_batch(%Turn.State{pending_effects: effects}) do
    Enum.take_while(effects, &match?(%Effect.Intent{kind: :operation}, &1))
  end

  defp run_operation_batch(
         %Turn.State{} = state,
         intents,
         %Capabilities{} = capabilities,
         opts
       ) do
    with {:ok, state, runnable_intents, replayed_results} <- preflight_operation_batch(state, intents, opts),
         {:ok, state, batch_results} <-
           execute_preflighted_operation_batch(state, runnable_intents, capabilities, opts) do
      ordered_results =
        Enum.map(intents, fn intent ->
          Map.fetch!(Map.merge(replayed_results, batch_results), intent.id)
        end)

      {:ok, ordered_results, state}
    end
  end

  defp preflight_operation_batch(%Turn.State{} = state, intents, opts) when is_list(intents) do
    Enum.reduce_while(intents, {:ok, state, [], %{}}, &preflight_operation_batch_intent(&1, &2, opts))
    |> case do
      {:ok, state, runnable_intents, replayed_results} ->
        {:ok, state, Enum.reverse(runnable_intents), replayed_results}

      other ->
        other
    end
  end

  defp preflight_operation_batch_intent(
         %Effect.Intent{} = intent,
         {:ok, %Turn.State{} = state, runnable_intents, replayed_results},
         opts
       ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        state = append_effect_trace(state, intent, :effect_replayed, [], opts)
        {:cont, {:ok, state, runnable_intents, Map.put(replayed_results, intent.id, result)}}

      nil ->
        preflight_uncached_operation_intent(state, intent, runnable_intents, replayed_results, opts)
    end
  end

  defp preflight_uncached_operation_intent(state, intent, runnable_intents, replayed_results, opts) do
    case preflight_operation_intent(state, intent, opts) do
      {:ok, state, intent} ->
        {:cont, {:ok, state, [intent | runnable_intents], replayed_results}}

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        {:halt, {:interrupt, interrupt, state}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp preflight_operation_intent(%Turn.State{} = state, %Effect.Intent{} = intent, opts) do
    with :ok <- validate_incomplete_effect_replay(state, intent) do
      state = append_effect_trace(state, intent, :effect_started, [], opts)

      case run_effect_controls(state, intent, opts) do
        {:ok, %Turn.State{} = state} ->
          intent = mark_operation_controls_allowed(intent)
          {:ok, replace_pending_effect(state, intent), intent}

        {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
          {:interrupt, interrupt, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_preflighted_operation_batch(%Turn.State{} = state, [], _capabilities, _opts) do
    {:ok, state, %{}}
  end

  defp execute_preflighted_operation_batch(
         %Turn.State{} = state,
         intents,
         %Capabilities{} = capabilities,
         opts
       ) do
    journal = Enum.reduce(intents, state.journal, &Effect.Journal.put_intent(&2, &1))
    state = %Turn.State{state | journal: journal}
    state = Enum.reduce(intents, state, &append_effect_trace(&2, &1, :capability_call_started, [], opts))

    case execute_operation_batch_workflow(intents, capabilities, journal, opts) do
      {:ok, results} ->
        state =
          results
          |> Map.values()
          |> Enum.reduce(state, fn result, %Turn.State{} = state ->
            %Turn.State{state | journal: Effect.Journal.put_result(state.journal, result)}
          end)

        state =
          Enum.reduce(intents, state, fn intent, state ->
            result = Map.fetch!(results, intent.id)

            state
            |> append_capability_result_trace(intent, result, opts)
            |> append_effect_result_trace(intent, result, opts)
          end)

        {:ok, state, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_operation_batch_workflow(intents, %Capabilities{} = capabilities, %Effect.Journal{} = journal, opts) do
    step_names = operation_batch_step_names(intents)

    workflow =
      intents
      |> Enum.zip(step_names)
      |> Enum.reduce(Workflow.new(name: :jidoka_operation_batch), fn {intent, step_name}, workflow ->
        workflow_step =
          Runic.step(
            fn _state ->
              call_operation_batch_step(^intent, ^capabilities, ^journal)
            end,
            name: step_name
          )

        Workflow.add(workflow, workflow_step)
      end)

    workflow =
      Workflow.react_until_satisfied(workflow, %{},
        async: true,
        max_concurrency: max_parallel_operations(opts),
        timeout: :infinity
      )

    results =
      intents
      |> Enum.zip(step_names)
      |> Enum.reduce_while({:ok, %{}}, fn {intent, step_name}, {:ok, acc} ->
        case workflow |> Workflow.raw_productions(step_name) |> List.last() do
          %Effect.Result{} = result ->
            {:cont, {:ok, Map.put(acc, intent.id, result)}}

          other ->
            {:halt,
             {:error,
              Error.normalize({:missing_operation_batch_result, intent.id, other},
                operation: effect_operation(intent),
                phase: :effect,
                intent_id: intent.id,
                effect_kind: intent.kind
              )}}
        end
      end)

    results
  rescue
    exception -> {:error, Error.normalize(exception, operation: :operation, phase: :effect)}
  catch
    kind, reason -> {:error, Error.normalize({kind, reason}, operation: :operation, phase: :effect)}
  end

  defp call_operation_batch_step(%Effect.Intent{} = intent, %Capabilities{} = capabilities, %Effect.Journal{} = journal) do
    case call_capability(intent, capabilities, journal) do
      {:ok, %Effect.Result{} = result} -> result
    end
  end

  defp operation_batch_step_names(intents) do
    intents
    |> Enum.with_index()
    |> Enum.map(fn {_intent, index} -> "operation_#{index}" end)
  end

  defp max_parallel_operations(opts) do
    opts
    |> Keyword.get(:max_parallel_operations, Config.default_max_parallel_operations())
    |> Config.normalize_positive_integer!(:max_parallel_operations)
  end

  defp mark_operation_controls_allowed(%Effect.Intent{} = intent) do
    metadata = Map.put(intent.metadata, "operation_controls_allowed", true)
    %Effect.Intent{intent | metadata: metadata}
  end

  defp replace_pending_effect(%Turn.State{} = state, %Effect.Intent{id: id} = intent) do
    pending_effects =
      Enum.map(state.pending_effects, fn
        %Effect.Intent{id: ^id} -> intent
        other -> other
      end)

    %Turn.State{state | pending_effects: pending_effects}
  end
end
