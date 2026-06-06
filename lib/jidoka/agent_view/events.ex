defmodule Jidoka.AgentView.Events do
  @moduledoc false

  alias Jidoka.Event
  alias Jidoka.Stream, as: EventStream
  alias Jidoka.Turn

  @spec apply_event(map(), Event.t() | term()) :: map()
  def apply_event(%{} = view, %Event{} = event) do
    view
    |> apply_stream_delta(event)
    |> append_runtime_event(event)
  end

  def apply_event(%{} = view, _event), do: view

  @spec visible_messages(map()) :: [map()]
  def visible_messages(%{streaming_message: nil, visible_messages: messages}), do: messages

  def visible_messages(%{streaming_message: streaming_message, visible_messages: messages}),
    do: messages ++ [streaming_message]

  @spec append_operation_events([map()], Turn.Result.t()) :: [map()]
  def append_operation_events(events, %Turn.Result{} = result) do
    existing_ids = MapSet.new(events, & &1.id)

    result
    |> operation_events()
    |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
    |> then(&(events ++ &1))
  end

  defp apply_stream_delta(%{} = view, %Event{} = event) do
    cond do
      is_binary(EventStream.text_delta(event)) ->
        update_streaming_message(view, event, :content, EventStream.text_delta(event))

      is_binary(EventStream.thinking_delta(event)) ->
        update_streaming_message(view, event, :thinking, EventStream.thinking_delta(event))

      true ->
        view
    end
  end

  defp update_streaming_message(%{} = view, %Event{} = event, :content, delta) do
    message = streaming_message(Map.get(view, :streaming_message), event)
    content = Map.get(message, :content, "") <> delta

    %{view | streaming_message: Map.put(message, :content, content), status: :running}
  end

  defp update_streaming_message(%{} = view, %Event{} = event, :thinking, delta) do
    message = streaming_message(Map.get(view, :streaming_message), event)
    thinking = Map.get(message, :thinking, "") <> delta

    message =
      message
      |> Map.put(:thinking, thinking)
      |> Map.update(:content, "Thinking...", fn
        "" -> "Thinking..."
        content -> content
      end)

    %{view | streaming_message: message, status: :running}
  end

  defp streaming_message(nil, %Event{} = event) do
    request_id = event.request_id || request_id()

    %{
      id: "streaming-" <> request_id,
      seq: -1,
      role: :assistant,
      content: "",
      request_id: request_id,
      streaming?: true
    }
  end

  defp streaming_message(%{} = message, _event), do: message

  defp append_runtime_event(%{} = view, %Event{event: :llm_delta}), do: view

  defp append_runtime_event(%{} = view, %Event{} = event) do
    projected = runtime_event(event)

    if Enum.any?(view.events, &(&1.id == projected.id)) do
      view
    else
      %{view | events: view.events ++ [projected]}
    end
  end

  defp runtime_event(%Event{} = event) do
    %{
      id: runtime_event_id(event),
      kind: event.event,
      label: event_label(event),
      payload: Event.to_map(event),
      refs: %{
        operation: event.operation,
        effect_id: event.effect_id,
        request_id: event.request_id
      }
    }
  end

  defp runtime_event_id(%Event{} = event) do
    [
      "event",
      event.request_id || "turn",
      event.seq,
      event.event,
      event.effect_id
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("-", &to_string/1)
  end

  defp event_label(%Event{operation: operation}) when is_binary(operation) do
    "#{humanize_event(:operation)}: #{operation}"
  end

  defp event_label(%Event{event: event}), do: humanize_event(event)

  defp humanize_event(event) do
    event
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp operation_events(%Turn.Result{} = result) do
    Enum.map(result.agent_state.operation_results, fn operation_result ->
      projection = Jidoka.project(operation_result)

      %{
        id: operation_result.effect_id || message_id("operation"),
        kind: :operation_result,
        label: "tool result: #{operation_result.operation}",
        payload: projection,
        refs: %{operation: operation_result.operation}
      }
    end)
  end

  defp message_id(prefix), do: Jidoka.Id.random(prefix)
  defp request_id, do: Jidoka.Id.random("agent_view")
end
