defmodule Jidoka.Trace do
  @moduledoc """
  Trace projection helpers used by the built-in trace extension.
  """

  alias Jidoka.Event

  @doc "Returns the core event names projected by the built-in trace extension."
  @spec events() :: [atom()]
  def events, do: Event.events()

  @doc "Projects core events into a compact, sequence-stable trace timeline."
  @spec timeline(list()) :: [map()]
  def timeline(events) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} -> timeline_event(event, index) end)
  end

  def timeline(_events), do: []

  defp timeline_event(%Event{} = event, _index) do
    event
    |> Event.to_map()
    |> Map.put(:extension, :trace)
  end

  defp timeline_event(%{} = event, index) do
    event
    |> Map.put_new(:seq, index)
    |> Map.put_new(:extension, :trace)
  end

  defp timeline_event(other, index) do
    %{seq: index, extension: :trace, event: :unknown_event, data: %{value: other}}
  end
end
