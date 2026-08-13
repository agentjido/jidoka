defmodule Jidoka.Runtime.EventDispatcher do
  @moduledoc false

  alias Jidoka.Event
  alias Jidoka.Runtime.EventSequence

  @message_tag :jidoka_turn_event
  @terminal_events [:turn_finished, :turn_failed, :turn_hibernated]

  @spec message_tag() :: atom()
  def message_tag, do: @message_tag

  @spec terminal?(Event.t()) :: boolean()
  def terminal?(%Event{event: event}), do: event in @terminal_events

  @spec emit(Event.t(), keyword()) :: :ok
  def emit(%Event{} = event, opts) when is_list(opts) do
    event = EventSequence.stamp(event)
    emit_to_mailbox(event, Keyword.get(opts, :stream_to))
    emit_to_callback(event, Keyword.get(opts, :on_event))
    Jidoka.Extension.RuntimeEvents.emit_runtime(event, opts)
    :ok
  end

  @spec emit_events([Event.t()], keyword()) :: :ok
  def emit_events(events, opts) when is_list(events) and is_list(opts) do
    Enum.each(events, &emit(&1, opts))
    :ok
  end

  @spec events(String.t(), keyword()) :: Enumerable.t()
  def events(request_id, opts \\ []) when is_binary(request_id) and is_list(opts) do
    timeout = Keyword.get(opts, :stream_event_timeout_ms, :infinity)

    Elixir.Stream.resource(
      fn -> %{request_id: request_id, done?: false, timeout: timeout} end,
      &next_event/1,
      fn _state -> :ok end
    )
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(%{request_id: request_id, timeout: timeout} = state) do
    receive do
      {@message_tag, %Event{request_id: ^request_id} = event} ->
        {[event], %{state | done?: terminal?(event)}}
    after
      timeout -> {:halt, %{state | done?: true}}
    end
  end

  defp emit_to_mailbox(%Event{} = event, pid) when is_pid(pid) do
    send(pid, {@message_tag, event})
    :ok
  end

  defp emit_to_mailbox(%Event{} = event, {:pid, pid}) when is_pid(pid),
    do: emit_to_mailbox(event, pid)

  defp emit_to_mailbox(_event, _sink), do: :ok

  defp emit_to_callback(%Event{} = event, callback) when is_function(callback, 1) do
    callback.(event)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_to_callback(_event, _callback), do: :ok
end
