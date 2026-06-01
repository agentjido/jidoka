defmodule Jidoka.Stream do
  @moduledoc """
  Request-scoped stream helpers for Jidoka turn events.

  The runtime remains terminal-result oriented, but callers that pass
  `stream_to: pid` or `on_event: fun` can observe `Jidoka.Event` values as the
  turn runs. This mirrors the request-owned streaming shape from Jidoka v1
  without depending on Jido.AI's internal event structs.
  """

  alias Jidoka.Event

  @message_tag :jidoka_turn_event
  @terminal_events [:turn_finished, :turn_failed, :turn_hibernated]

  @type t :: %__MODULE__{
          request: Jidoka.Chat.Request.t(),
          events: Enumerable.t()
        }

  defstruct [:request, :events]

  @doc "Builds a stream wrapper for an async chat request."
  @spec new(Jidoka.Chat.Request.t(), keyword()) :: t()
  def new(%Jidoka.Chat.Request{} = request, opts \\ []) when is_list(opts) do
    %__MODULE__{request: request, events: events(request.request_id, opts)}
  end

  @doc "Waits for the final normalized result for a stream wrapper."
  @spec await(t(), keyword()) :: term()
  def await(%__MODULE__{request: %Jidoka.Chat.Request{} = request}, opts \\ []) do
    Jidoka.Chat.Request.await(request, opts)
  end

  @doc "Returns the mailbox tag used for streamed turn events."
  @spec message_tag() :: atom()
  def message_tag, do: @message_tag

  @doc "Returns true when an event terminates a turn stream."
  @spec terminal?(Event.t()) :: boolean()
  def terminal?(%Event{event: event}), do: event in @terminal_events

  @doc "Extracts a content delta from an `:llm_delta` event."
  @spec text_delta(Event.t()) :: String.t() | nil
  def text_delta(%Event{event: :llm_delta, data: data}) when is_map(data) do
    if delta_kind(data) in [:content, "content", nil], do: string_value(data, :delta)
  end

  def text_delta(_event), do: nil

  @doc "Extracts a thinking/reasoning delta from an `:llm_delta` event."
  @spec thinking_delta(Event.t()) :: String.t() | nil
  def thinking_delta(%Event{event: :llm_delta, data: data}) when is_map(data) do
    if delta_kind(data) in [:thinking, :reasoning, "thinking", "reasoning"],
      do: string_value(data, :delta)
  end

  def thinking_delta(_event), do: nil

  @doc """
  Emits one event to the stream sinks configured for a running turn.

  Custom capabilities can call this when they want to surface incremental
  provider output, for example `:llm_delta` events from a streaming model.
  """
  @spec emit(Event.t(), keyword()) :: :ok
  def emit(%Event{} = event, opts) when is_list(opts) do
    emit_to_mailbox(event, Keyword.get(opts, :stream_to))
    emit_to_callback(event, Keyword.get(opts, :on_event))
    :ok
  end

  @doc false
  @spec emit_events([Event.t()], keyword()) :: :ok
  def emit_events(events, opts) when is_list(events) and is_list(opts) do
    Enum.each(events, &emit(&1, opts))
    :ok
  end

  @doc """
  Builds a mailbox-backed enumerable for a request id.

  This is intentionally small: it consumes already-emitted Jidoka events from
  the caller mailbox and halts on a terminal event or timeout.
  """
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
      timeout ->
        {:halt, %{state | done?: true}}
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

  defp delta_kind(data), do: Map.get(data, :chunk_type, Map.get(data, "chunk_type"))

  defp string_value(data, key) do
    case Map.get(data, key, Map.get(data, Atom.to_string(key))) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end
end

defimpl Enumerable, for: Jidoka.Stream do
  def reduce(%Jidoka.Stream{events: events}, acc, fun), do: Enumerable.reduce(events, acc, fun)
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _event), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end
