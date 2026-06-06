defmodule Jidoka.Runtime.EffectTrace do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Error
  alias Jidoka.Stream, as: EventStream
  alias Jidoka.Turn

  @spec append_capability_result(Turn.State.t(), Effect.Intent.t(), Effect.Result.t(), keyword()) ::
          Turn.State.t()
  def append_capability_result(%Turn.State{} = state, %Effect.Intent{} = intent, %Effect.Result{} = result, opts) do
    event =
      case result.status do
        :ok -> :capability_call_completed
        :error -> :capability_call_failed
      end

    append(state, intent, event, [error: result_error(result)], opts)
  end

  @spec append_effect_result(Turn.State.t(), Effect.Intent.t(), Effect.Result.t(), keyword()) :: Turn.State.t()
  def append_effect_result(%Turn.State{} = state, %Effect.Intent{} = intent, %Effect.Result{} = result, opts) do
    event =
      case result.status do
        :ok -> :effect_completed
        :error -> :effect_failed
      end

    append(state, intent, event, [error: result_error(result)], opts)
  end

  @spec append(Turn.State.t(), Effect.Intent.t(), atom(), keyword(), keyword()) :: Turn.State.t()
  def append(%Turn.State{} = state, %Effect.Intent{} = intent, event, attrs, opts) do
    trace_attrs =
      [
        agent_id: state.spec.id,
        request_id: request_id(state, intent),
        loop_index: loop_index(state, intent),
        effect_id: intent.id,
        effect_kind: intent.kind,
        operation: operation(intent),
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

  @spec emit_events([Jidoka.Event.t()], keyword()) :: :ok
  def emit_events(events, opts), do: EventStream.emit_events(events, opts)

  @spec request_id(Turn.State.t(), Effect.Intent.t()) :: String.t() | nil
  def request_id(%Turn.State{} = state, %Effect.Intent{} = intent) do
    Map.get(intent.payload, :request_id) ||
      Map.get(intent.payload, "request_id") ||
      state.request.request_id
  end

  @spec loop_index(Turn.State.t(), Effect.Intent.t()) :: non_neg_integer() | nil
  def loop_index(%Turn.State{} = state, %Effect.Intent{} = intent) do
    Map.get(intent.payload, :loop_index) ||
      Map.get(intent.payload, "loop_index") ||
      state.loop_index
  end

  @spec operation(Effect.Intent.t()) :: String.t() | nil
  def operation(%Effect.Intent{kind: :operation, payload: payload}) do
    Map.get(payload, :name) || Map.get(payload, "name")
  end

  def operation(_intent), do: nil

  defp result_error(%Effect.Result{status: :error, output: output}), do: Error.to_map(output)
  defp result_error(_result), do: nil
end
