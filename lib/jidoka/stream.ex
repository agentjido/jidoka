defmodule Jidoka.Stream do
  @moduledoc """
  Request-scoped stream helpers for Jidoka turn events.

  The runtime remains terminal-result oriented, but callers that pass
  `stream_to: pid` or `on_event: fun` can observe `Jidoka.Event` values as the
  turn runs. This mirrors the request-owned streaming shape from Jidoka v1
  without depending on Jido.AI's internal event structs.
  """

  alias Jidoka.Chat.Async, as: AsyncChat
  alias Jidoka.Event
  alias Jidoka.Runtime.EventDispatcher
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request:
                Schema.typed_struct(
                  :"Elixir.Jidoka.Chat.Request",
                  quote(do: Jidoka.Chat.Request.t())
                ),
              events: Zoi.any(typespec: quote(do: Enumerable.t()))
            },
            coerce: true,
            unrecognized_keys: :error
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a stream wrapper for an async chat request."
  @spec new(Jidoka.Chat.Request.t(), keyword()) :: t()
  def new(%Jidoka.Chat.Request{} = request, opts \\ []) when is_list(opts) do
    Schema.parse!(@schema, %{request: request, events: events(request.request_id, opts)}, "stream")
  end

  @doc "Waits for the final normalized result for a stream wrapper."
  @spec await(t(), keyword()) :: term()
  def await(%__MODULE__{request: %Jidoka.Chat.Request{} = request}, opts \\ []) do
    AsyncChat.await(request, opts)
  end

  @doc "Returns the mailbox tag used for streamed turn events."
  @spec message_tag() :: atom()
  defdelegate message_tag(), to: EventDispatcher

  @doc "Returns true when an event terminates a turn stream."
  @spec terminal?(Event.t()) :: boolean()
  defdelegate terminal?(event), to: EventDispatcher

  @doc "Extracts a content delta from an `:llm_delta` event."
  @spec text_delta(Event.t()) :: String.t() | nil
  def text_delta(%Event{event: :llm_delta, data: data}) when is_map(data) do
    if Map.get(data, :chunk_type) in [:content, nil], do: string_value(data, :delta)
  end

  def text_delta(_event), do: nil

  @doc "Extracts a thinking/reasoning delta from an `:llm_delta` event."
  @spec thinking_delta(Event.t()) :: String.t() | nil
  def thinking_delta(%Event{event: :llm_delta, data: data}) when is_map(data) do
    if Map.get(data, :chunk_type) in [:thinking, :reasoning], do: string_value(data, :delta)
  end

  def thinking_delta(_event), do: nil

  @doc "Returns the provider-neutral model record carried by an `:llm_delta` event."
  @spec model_record(Event.t()) :: map() | nil
  def model_record(%Event{event: :llm_delta, data: %{type: type} = data}) when is_atom(type),
    do: data

  def model_record(%Event{event: :llm_delta, data: %{chunk_type: :content} = data}),
    do: Map.put(data, :type, :text_delta)

  def model_record(%Event{event: :llm_delta, data: %{chunk_type: type} = data})
      when type in [:thinking, :reasoning],
      do: Map.put(data, :type, :reasoning_delta)

  def model_record(%Event{}), do: nil

  @doc """
  Emits one event to the stream sinks configured for a running turn.

  Custom capabilities can call this when they want to surface incremental
  provider output, for example `:llm_delta` events from a streaming model.
  """
  @spec emit(Event.t(), keyword()) :: :ok
  defdelegate emit(event, opts), to: EventDispatcher

  @doc false
  @spec emit_events([Event.t()], keyword()) :: :ok
  defdelegate emit_events(events, opts), to: EventDispatcher

  @doc """
  Builds a mailbox-backed enumerable for a request id.

  This is intentionally small: it consumes already-emitted Jidoka events from
  the caller mailbox and halts on a terminal event or timeout.
  """
  @spec events(String.t(), keyword()) :: Enumerable.t()
  def events(request_id, opts \\ []), do: EventDispatcher.events(request_id, opts)

  defp string_value(data, key) do
    case Map.get(data, key) do
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
