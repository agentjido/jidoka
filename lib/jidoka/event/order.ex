defmodule Jidoka.Event.Order do
  @moduledoc """
  Public order contract for one streamed request.

  The request controller is the single sequence owner. It assigns contiguous
  `seq` values starting at zero, forwards only events that classify onto the
  request, and emits exactly one terminal event. Completion, cancellation,
  timeout, and owner-exit races must still produce that one terminal result.
  A late or unassignable event cannot create a second terminal.
  """

  alias Jidoka.Event

  @terminal_events [:turn_finished, :turn_failed, :turn_hibernated]

  @type violation ::
          :empty_events
          | :missing_terminal
          | {:missing_request_id, non_neg_integer()}
          | {:mixed_request_id, String.t(), String.t(), non_neg_integer()}
          | {:unexpected_sequence, non_neg_integer(), non_neg_integer()}
          | {:event_after_terminal, non_neg_integer()}

  @type classification ::
          :accept
          | {:reject, :missing_request_id | :foreign_request_id}

  @doc "Checks one ordered event stream."
  @spec validate([Event.t()]) :: :ok | {:error, violation()}
  def validate([]), do: {:error, :empty_events}

  def validate([%Event{request_id: request_id} | _events] = events)
      when is_binary(request_id) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, false}, fn {%Event{} = event, index}, {:ok, terminal?} ->
      cond do
        not is_binary(event.request_id) ->
          {:halt, {:error, {:missing_request_id, index}}}

        event.request_id != request_id ->
          {:halt, {:error, {:mixed_request_id, request_id, event.request_id, index}}}

        event.seq != index ->
          {:halt, {:error, {:unexpected_sequence, index, event.seq}}}

        terminal? ->
          {:halt, {:error, {:event_after_terminal, index}}}

        true ->
          {:cont, {:ok, event.event in @terminal_events}}
      end
    end)
    |> case do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :missing_terminal}
      {:error, _violation} = error -> error
    end
  end

  def validate([%Event{} | _events]), do: {:error, {:missing_request_id, 0}}

  @doc "Classifies whether an event belongs to one request sequence owner."
  @spec classify(Event.t(), String.t()) :: classification()
  def classify(%Event{request_id: request_id}, owner_id)
      when is_binary(owner_id) and is_binary(request_id) do
    if request_id == owner_id, do: :accept, else: {:reject, :foreign_request_id}
  end

  def classify(%Event{}, owner_id) when is_binary(owner_id), do: {:reject, :missing_request_id}

  @doc "Returns true when an event closes an ordered request stream."
  @spec terminal?(Event.t()) :: boolean()
  def terminal?(%Event{event: event}), do: event in @terminal_events

  @doc "Returns the event names that close an ordered request stream."
  @spec terminal_events() :: [atom()]
  def terminal_events, do: @terminal_events
end
