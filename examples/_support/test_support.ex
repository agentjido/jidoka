defmodule JidokaExamples.TestSupport do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Event

  @spec count_results(Effect.Journal.t(), Effect.Intent.kind()) :: non_neg_integer()
  def count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  @spec timeline([Event.t()] | [map()]) :: [map()]
  def timeline([]), do: []
  def timeline([%Event{} | _rest] = events), do: Jidoka.Trace.timeline(events)
  def timeline([%{} | _rest] = timeline), do: timeline

  @spec event_index([Event.t()] | [map()], atom(), keyword()) :: non_neg_integer() | nil
  def event_index(events_or_timeline, event, filters \\ []) when is_atom(event) do
    events_or_timeline
    |> timeline()
    |> Enum.find_index(fn item ->
      item.event == event and
        Enum.all?(filters, fn {key, value} -> get_in(item, key_path(key)) == value end)
    end)
  end

  @spec assert_ordered!([non_neg_integer() | nil]) :: :ok
  def assert_ordered!(indexes) do
    if Enum.any?(indexes, &is_nil/1) or indexes != Enum.sort(indexes) or Enum.uniq(indexes) != indexes do
      raise ExUnit.AssertionError,
        message: "expected distinct ordered event indexes, got: #{inspect(indexes)}"
    end

    :ok
  end

  defp key_path(key) when is_atom(key), do: [key]
  defp key_path(key) when is_list(key), do: key
end
