defmodule Jidoka.Extension.RuntimeEvents do
  @moduledoc "Public bridge from Jidoka runtime events to the extension event protocol."

  alias Jidoka.Event, as: RuntimeEvent
  alias Jidoka.Extension.{Dispatcher, Event}
  alias Jidoka.Runtime.Limits

  @doc "Maps and emits a core runtime event when an extension dispatcher is present."
  @spec emit_runtime(RuntimeEvent.t(), keyword()) :: :ok
  def emit_runtime(%RuntimeEvent{} = runtime_event, opts) do
    with dispatcher when not is_nil(dispatcher) <- Keyword.get(opts, :extension_dispatcher),
         {:ok, event} <- Event.new(event_attrs(runtime_event, opts), event_opts(opts)),
         {:ok, _evidence} <- Dispatcher.dispatch(dispatcher, event, dispatcher_opts(opts)) do
      :ok
    else
      _result -> :ok
    end
  end

  @doc "Emits a session or automation boundary event through the same protocol."
  @spec emit(String.t(), map(), keyword()) :: :ok
  def emit(name, attrs, opts) when is_binary(name) and is_map(attrs) do
    with dispatcher when not is_nil(dispatcher) <- Keyword.get(opts, :extension_dispatcher),
         {:ok, event} <- Event.new(Map.put(attrs, :name, name), event_opts(opts)),
         {:ok, _evidence} <- Dispatcher.dispatch(dispatcher, event, dispatcher_opts(opts)) do
      :ok
    else
      _result -> :ok
    end
  end

  defp event_attrs(runtime_event, opts) do
    %{
      name: event_name(runtime_event),
      session_ref: Keyword.get(opts, :session_id),
      request_ref: runtime_event.request_id,
      turn_ref: runtime_event.request_id,
      data: runtime_data(runtime_event)
    }
  end

  defp runtime_data(runtime_event) do
    runtime_event
    |> RuntimeEvent.to_map()
    |> Map.drop([:request_id])
    |> Map.put(:core_event, Atom.to_string(runtime_event.event))
  end

  defp event_name(%RuntimeEvent{event: :turn_started}), do: "turn.start"

  defp event_name(%RuntimeEvent{event: event}) when event in [:turn_finished, :turn_hibernated, :turn_failed],
    do: "turn.end"

  defp event_name(%RuntimeEvent{event: :llm_delta}), do: "model.update"
  defp event_name(%RuntimeEvent{event: :operation_observed}), do: "tool.update"
  defp event_name(%RuntimeEvent{event: :capability_call_started, effect_kind: :llm}), do: "model.start"
  defp event_name(%RuntimeEvent{event: :capability_call_completed, effect_kind: :llm}), do: "model.end"
  defp event_name(%RuntimeEvent{event: :capability_call_failed, effect_kind: :llm}), do: "model.error"
  defp event_name(%RuntimeEvent{event: :capability_call_started, effect_kind: :operation}), do: "tool.before"
  defp event_name(%RuntimeEvent{event: :capability_call_completed, effect_kind: :operation}), do: "tool.after"
  defp event_name(%RuntimeEvent{event: :capability_call_failed, effect_kind: :operation}), do: "tool.error"
  defp event_name(%RuntimeEvent{}), do: "turn.update"

  defp event_opts(opts) do
    [
      id_generator: Keyword.get(opts, :extension_event_id_generator),
      clock: Keyword.get(opts, :extension_clock)
    ]
  end

  defp dispatcher_opts(opts) do
    dispatcher_opts = Keyword.take(opts, [:subscriber_timeout_ms, :call_timeout, :cancellation])

    case Limits.capability_timeout(opts, :infinity) do
      :infinity ->
        dispatcher_opts

      timeout ->
        Keyword.update(dispatcher_opts, :subscriber_timeout_ms, timeout, &min(&1, timeout))
    end
  end
end
