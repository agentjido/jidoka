defmodule Jidoka.Runtime.OperationGroupCheckpoint do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Runtime.DurableCheckpoint
  alias Jidoka.Runtime.EffectTrace
  alias Jidoka.Runtime.Limits
  alias Jidoka.Turn

  @type coordinator :: pid()

  @doc false
  @spec start(Turn.State.t(), [Effect.Intent.t()], keyword()) ::
          {:ok, coordinator()} | {:error, term()}
  def start(%Turn.State{} = state, intents, opts) when is_list(intents) and intents != [] do
    with {:ok, group} <- Effect.OperationGroup.new(intents),
         {:ok, group} <- restore_group(group, state.journal, intents) do
      start_coordinator(state, group, intents, opts)
    end
  end

  @doc false
  @spec before_call(coordinator(), Effect.Intent.t(), keyword()) ::
          {:ok, Effect.Journal.t()} | {:error, term()}
  def before_call(coordinator, %Effect.Intent{} = intent, opts) when is_pid(coordinator) do
    Elixir.Agent.get_and_update(
      coordinator,
      &before_call_state(&1, intent, opts),
      :infinity
    )
  end

  @doc false
  @spec after_result(coordinator(), Effect.Intent.t(), Effect.Result.t(), keyword()) ::
          :ok | {:error, term()}
  def after_result(coordinator, %Effect.Intent{} = intent, %Effect.Result{} = result, opts)
      when is_pid(coordinator) do
    Elixir.Agent.get_and_update(
      coordinator,
      &after_result_state(&1, intent, result, opts),
      :infinity
    )
  end

  @doc false
  @spec state(coordinator()) :: Turn.State.t()
  def state(coordinator) when is_pid(coordinator) do
    Elixir.Agent.get(coordinator, & &1.state, :infinity)
  end

  @doc false
  @spec stop(coordinator()) :: :ok
  def stop(coordinator) when is_pid(coordinator) do
    if Process.alive?(coordinator), do: Elixir.Agent.stop(coordinator, :normal, :infinity)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp checkpoint(coordinator, intent, stage, opts) do
    Elixir.Agent.get(
      coordinator,
      fn data -> DurableCheckpoint.persist(data.state, intent, stage, opts) end,
      :infinity
    )
  end

  defp start_coordinator(%Turn.State{} = state, group, intents, opts) do
    journal = Effect.Journal.put_operation_group(state.journal, group)
    state = %Turn.State{state | journal: journal}

    case Elixir.Agent.start_link(fn -> %{state: state, group: group} end) do
      {:ok, coordinator} -> finish_start(coordinator, hd(intents), opts)
      {:error, _reason} = error -> error
    end
  end

  defp finish_start(coordinator, intent, opts) do
    case checkpoint(coordinator, intent, :operation_group, opts) do
      :ok -> {:ok, coordinator}
      {:error, reason} -> stop_with_error(coordinator, reason)
    end
  end

  defp before_call_state(
         %{state: %Turn.State{} = state, group: current_group} = data,
         intent,
         opts
       ) do
    case Effect.OperationGroup.start(current_group, intent) do
      {:ok, group} -> persist_started_call(data, state, group, intent, opts)
      {:error, reason} -> {{:error, reason}, data}
    end
  end

  defp persist_started_call(data, %Turn.State{} = state, group, intent, opts) do
    journal =
      state.journal
      |> Effect.Journal.put_operation_group(group)
      |> Effect.Journal.put_intent(intent)

    state =
      %Turn.State{state | journal: journal}
      |> EffectTrace.append(intent, :capability_call_started, [], opts)

    result =
      case DurableCheckpoint.persist(state, intent, :intent, opts) do
        :ok -> {:ok, journal}
        {:error, reason} -> {:error, reason}
      end

    {result, %{data | state: state, group: group}}
  end

  defp after_result_state(
         %{state: %Turn.State{} = state, group: current_group} = data,
         intent,
         result,
         opts
       ) do
    case Effect.OperationGroup.complete(current_group, intent) do
      {:ok, group} -> persist_completed_call(data, state, group, intent, result, opts)
      {:error, reason} -> {{:error, reason}, data}
    end
  end

  defp persist_completed_call(data, %Turn.State{} = state, group, intent, result, opts) do
    {limit_status, state} =
      case Limits.record_effect_result(state, result) do
        {:ok, state} -> {:ok, state}
        {:error, reason, state} -> {{:error, reason}, state}
      end

    journal =
      state.journal
      |> Effect.Journal.put_operation_group(group)
      |> Effect.Journal.put_result(result)

    state =
      %Turn.State{state | journal: journal}
      |> EffectTrace.append_capability_result(intent, result, opts)
      |> EffectTrace.append_effect_result(intent, result, opts)

    checkpoint =
      case DurableCheckpoint.persist(state, intent, :result, opts) do
        :ok -> limit_status
        {:error, _reason} = error -> error
      end

    {checkpoint, %{data | state: state, group: group}}
  end

  defp restore_group(group, journal, intents) do
    group = Effect.Journal.operation_group(journal, group.id) || group

    Enum.reduce_while(intents, {:ok, group}, fn intent, {:ok, group} ->
      with {:ok, group} <- maybe_start(group, journal, intent),
           {:ok, group} <- maybe_complete(group, journal, intent) do
        {:cont, {:ok, group}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_start(group, journal, intent) do
    if Effect.Journal.intent_recorded?(journal, intent),
      do: Effect.OperationGroup.start(group, intent),
      else: {:ok, group}
  end

  defp maybe_complete(group, journal, intent) do
    if Effect.Journal.result_for(journal, intent),
      do: Effect.OperationGroup.complete(group, intent),
      else: {:ok, group}
  end

  defp stop_with_error(coordinator, reason) do
    stop(coordinator)
    {:error, reason}
  end
end
