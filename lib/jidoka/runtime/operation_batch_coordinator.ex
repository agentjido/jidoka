defmodule Jidoka.Runtime.OperationBatchCoordinator do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Operation.Continuation
  alias Jidoka.Review.Interrupt
  alias Jidoka.Runtime.Capabilities
  alias Jidoka.Runtime.EffectTrace
  alias Jidoka.Runtime.Limits
  alias Jidoka.Runtime.OperationGroupCheckpoint
  alias Jidoka.Turn

  @type preflight ::
          (Turn.State.t(), Effect.Intent.t(), Capabilities.t(), keyword() ->
             {:ok, Turn.State.t(), Effect.Intent.t()}
             | {:interrupt, Interrupt.t(), Turn.State.t()}
             | {:error, term()})

  @spec run(Turn.State.t(), [Effect.Intent.t()], Capabilities.t(), keyword(), preflight()) ::
          {:ok, [Effect.Result.t()], Turn.State.t()}
          | {:hibernate, [Continuation.t()], Turn.State.t()}
          | {:interrupt, Interrupt.t(), Turn.State.t()}
          | {:error, term()}
  def run(%Turn.State{} = state, intents, %Capabilities{} = capabilities, opts, preflight)
      when is_list(intents) and is_list(opts) and is_function(preflight, 4) do
    with {:ok, state} <- Limits.reserve_operation_group(state, intents),
         {:ok, state, runnable_intents, replayed_results} <-
           preflight_batch(state, intents, capabilities, opts, preflight) do
      state
      |> execute_preflighted_batch(intents, runnable_intents, capabilities, opts)
      |> finalize_batch(intents, replayed_results)
    end
  end

  defp finalize_batch({:ok, state, batch_results}, intents, replayed_results) do
    all_results = Map.merge(replayed_results, batch_results)
    ordered_results = Enum.map(intents, &Map.fetch!(all_results, &1.id))
    {:ok, ordered_results, state}
  end

  defp finalize_batch({:hibernate, continuations, state}, _intents, _replayed_results),
    do: {:hibernate, continuations, state}

  defp finalize_batch({:error, _reason} = error, _intents, _replayed_results), do: error

  defp preflight_batch(state, intents, capabilities, opts, preflight) do
    Enum.reduce_while(
      intents,
      {:ok, state, [], %{}},
      &preflight_batch_intent(&1, &2, capabilities, opts, preflight)
    )
    |> case do
      {:ok, state, runnable_intents, replayed_results} ->
        {:ok, state, Enum.reverse(runnable_intents), replayed_results}

      other ->
        other
    end
  end

  defp preflight_batch_intent(
         %Effect.Intent{} = intent,
         {:ok, %Turn.State{} = state, runnable_intents, replayed_results},
         capabilities,
         opts,
         preflight
       ) do
    case Effect.Journal.result_for(state.journal, intent) do
      %Effect.Result{} = result ->
        state = EffectTrace.append(state, intent, :effect_replayed, [], opts)
        {:cont, {:ok, state, runnable_intents, Map.put(replayed_results, intent.id, result)}}

      nil ->
        preflight_uncached_intent(
          state,
          intent,
          runnable_intents,
          replayed_results,
          capabilities,
          opts,
          preflight
        )
    end
  end

  defp preflight_uncached_intent(
         state,
         intent,
         runnable_intents,
         replayed_results,
         capabilities,
         opts,
         preflight
       ) do
    case preflight.(state, intent, capabilities, opts) do
      {:ok, state, intent} ->
        {:cont, {:ok, state, [intent | runnable_intents], replayed_results}}

      {:interrupt, %Interrupt{} = interrupt, %Turn.State{} = state} ->
        {:halt, {:interrupt, interrupt, state}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp execute_preflighted_batch(%Turn.State{} = state, _group_intents, [], _capabilities, _opts) do
    {:ok, state, %{}}
  end

  defp execute_preflighted_batch(
         %Turn.State{} = state,
         group_intents,
         runnable_intents,
         %Capabilities{} = capabilities,
         opts
       ) do
    with {:ok, coordinator} <- OperationGroupCheckpoint.start(state, group_intents, opts) do
      try do
        execute_checkpointed_batch(coordinator, state, runnable_intents, capabilities, opts)
      after
        OperationGroupCheckpoint.stop(coordinator)
      end
    end
  end

  defp execute_checkpointed_batch(coordinator, state, intents, capabilities, opts) do
    batch_opts =
      opts
      |> Keyword.put(
        :operation_group_before_call,
        &OperationGroupCheckpoint.before_call(coordinator, &1, opts)
      )
      |> Keyword.put(
        :operation_group_after_result,
        &OperationGroupCheckpoint.after_result(coordinator, &1, &2, opts)
      )

    case execute_batch(state, intents, capabilities, state.journal, batch_opts) do
      {:ok, results} -> finalize_checkpointed_batch(coordinator, intents, results, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_checkpointed_batch(coordinator, intents, results, opts) do
    state = OperationGroupCheckpoint.state(coordinator)
    continuations = continuation_results(results)
    missing = Enum.reject(intents, &Effect.Journal.result_for(state.journal, &1))

    cond do
      continuations != [] and continuation_intent_ids(continuations) == intent_ids(missing) ->
        {:hibernate, continuations, state}

      continuations != [] ->
        {:error, {:operation_batch_continuation_mismatch, continuation_intent_ids(continuations), intent_ids(missing)}}

      missing == [] ->
        {:ok, state, results}

      is_function(Keyword.get(opts, :durable_checkpoint), 3) ->
        {:error, {:operation_batch_checkpoint_callbacks_not_used, Enum.map(missing, & &1.id)}}

      true ->
        checkpoint_untracked_results(coordinator, missing, results, opts)
    end
  end

  defp checkpoint_untracked_results(coordinator, intents, results, opts) do
    Enum.reduce_while(intents, :ok, fn intent, :ok ->
      result = Map.fetch!(results, intent.id)

      with {:ok, _journal} <- OperationGroupCheckpoint.before_call(coordinator, intent, opts),
           :ok <- OperationGroupCheckpoint.after_result(coordinator, intent, result, opts) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, OperationGroupCheckpoint.state(coordinator), results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp continuation_results(results) do
    results
    |> Map.values()
    |> Enum.filter(&match?(%Continuation{}, &1))
    |> Enum.sort_by(& &1.intent_id)
  end

  defp continuation_intent_ids(continuations), do: Enum.map(continuations, & &1.intent_id)
  defp intent_ids(intents), do: intents |> Enum.map(& &1.id) |> Enum.sort()

  defp execute_batch(state, intents, capabilities, journal, opts) do
    case Keyword.fetch(opts, :operation_batch_executor) do
      {:ok, executor} when is_function(executor, 5) ->
        executor.(state, intents, capabilities, journal, opts)

      {:ok, executor} ->
        {:error, {:invalid_operation_batch_executor, executor}}

      :error ->
        {:error, :missing_operation_batch_executor}
    end
  rescue
    exception -> {:error, {:operation_batch_execution_failed, exception}}
  catch
    kind, reason -> {:error, {:operation_batch_execution_failed, {kind, reason}}}
  end
end
