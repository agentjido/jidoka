defmodule Jidoka.TestSupport do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Event

  @spec count_results(Effect.Journal.t(), Effect.Intent.kind()) :: non_neg_integer()
  def count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  @spec final_llm(String.t(), keyword()) :: Jidoka.Runtime.Capabilities.llm_capability()
  def final_llm(content, opts \\ []) when is_binary(content) do
    result = Keyword.get(opts, :result)

    fn _intent, _journal ->
      {:ok, %{type: :final, content: content, result: result}}
    end
  end

  @spec operation_llm(String.t(), map()) :: Jidoka.Runtime.Capabilities.llm_capability()
  def operation_llm(name, arguments \\ %{}) when is_binary(name) and is_map(arguments) do
    fn _intent, _journal ->
      {:ok, %{type: :operation, name: name, arguments: arguments}}
    end
  end

  @spec operation_then_final_llm(String.t(), map(), String.t()) :: Jidoka.Runtime.Capabilities.llm_capability()
  def operation_then_final_llm(name, arguments, content)
      when is_binary(name) and is_map(arguments) and is_binary(content) do
    fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: name, arguments: arguments}}
        _count -> {:ok, %{type: :final, content: content}}
      end
    end
  end

  @spec timeline([Event.t()] | [map()]) :: [map()]
  def timeline([]), do: []
  def timeline([%Event{} | _rest] = events), do: Jidoka.Extensions.Trace.timeline(events)
  def timeline([%{} | _rest] = timeline), do: timeline

  @spec event_index([Event.t()] | [map()], atom()) :: non_neg_integer() | nil
  def event_index(events_or_timeline, event) when is_atom(event) do
    events_or_timeline
    |> timeline()
    |> Enum.find_index(&(&1.event == event))
  end

  @spec operation_control_index([Event.t()] | [map()], String.t()) :: non_neg_integer() | nil
  def operation_control_index(events_or_timeline, control_name) when is_binary(control_name) do
    events_or_timeline
    |> timeline()
    |> Enum.find_index(
      &match?(
        %{event: :control_allowed, data: %{boundary: :operation, control: ^control_name}},
        &1
      )
    )
  end

  @spec operation_capability_index([Event.t()] | [map()], String.t()) :: non_neg_integer() | nil
  def operation_capability_index(events_or_timeline, operation) when is_binary(operation) do
    events_or_timeline
    |> timeline()
    |> Enum.find_index(
      &match?(
        %{event: :capability_call_started, effect_kind: :operation, operation: ^operation},
        &1
      )
    )
  end
end
