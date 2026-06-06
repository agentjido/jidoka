defmodule Jidoka.Debug.Diagnostics do
  @moduledoc false

  alias Jidoka.Debug.ReplayDiagnostics
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.{Replay, Session}
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @spec diagnose(term()) :: {:ok, ReplayDiagnostics.t()} | {:error, term()}
  def diagnose(%Turn.Result{} = result) do
    diagnostics_from_parts(
      journal: result.journal,
      events: result.events,
      pending_reviews: [],
      metadata: %{source: :turn_result}
    )
  end

  def diagnose(%AgentSnapshot{} = snapshot) do
    diagnostics_from_parts(
      journal: snapshot.turn_state.journal,
      events: snapshot.turn_state.events,
      pending_effects: snapshot.turn_state.pending_effects,
      pending_reviews: pending_reviews(snapshot),
      metadata: %{source: :snapshot, snapshot_id: snapshot.snapshot_id}
    )
  end

  def diagnose(%Session{} = session) do
    with {:ok, replay} <- Harness.replay(session), do: diagnose(replay)
  end

  def diagnose(%Replay{} = replay) do
    diagnostics_from_parts(
      journal: replay.journal,
      events: replay.timeline,
      pending_effects: replay_pending_effects(replay),
      pending_reviews: replay.pending_reviews,
      metadata: %{source: :replay, session_id: replay.session_id}
    )
  end

  def diagnose(%Effect.Journal{} = journal) do
    diagnostics_from_parts(journal: journal, events: [], pending_reviews: [], metadata: %{source: :journal})
  end

  def diagnose(other), do: {:error, {:unsupported_replay_diagnostics_target, other}}

  @spec diagnose!(term()) :: ReplayDiagnostics.t()
  def diagnose!(target) do
    case diagnose(target) do
      {:ok, diagnostics} -> diagnostics
      {:error, reason} -> ReplayDiagnostics.new!(status: :failed, warnings: [inspect(reason)])
    end
  end

  defp diagnostics_from_parts(parts) do
    {journal_intents, results} = journal_parts(Keyword.get(parts, :journal))
    intents = merge_intents(journal_intents, Keyword.get(parts, :pending_effects, []))
    events = Keyword.get(parts, :events, [])
    pending_reviews = Keyword.get(parts, :pending_reviews, [])

    result_ids = MapSet.new(Enum.map(results, &map_get(&1, :intent_id)))
    missing = Enum.reject(intents, &(map_get(&1, :id) in result_ids))
    failed_results = Enum.filter(results, &(map_get(&1, :status) == :error))
    unsafe = Enum.filter(intents, &(map_get(&1, :idempotency) == :unsafe_once))
    failed_events = Enum.filter(events, &failed_event?/1)

    ReplayDiagnostics.new(
      status: diagnostics_status(missing, failed_results, pending_reviews, failed_events),
      intent_count: length(intents),
      result_count: length(results),
      event_count: length(events),
      missing_effect_results: Enum.map(missing, &Jidoka.project/1),
      failed_effect_results: Enum.map(failed_results, &Jidoka.project/1),
      unsafe_effects: Enum.map(unsafe, &Jidoka.project/1),
      pending_reviews: Enum.map(pending_reviews, &Jidoka.project/1),
      failed_events: Enum.map(failed_events, &Jidoka.project/1),
      warnings: warnings(missing, failed_results, unsafe, pending_reviews, failed_events),
      metadata: Keyword.get(parts, :metadata, %{})
    )
  end

  defp diagnostics_status(_missing, _failed, [_review | _rest], _failed_events), do: :waiting
  defp diagnostics_status(_missing, [_failed | _rest], _pending, _failed_events), do: :failed
  defp diagnostics_status(_missing, _failed, _pending, [_event | _rest]), do: :failed
  defp diagnostics_status([_missing | _rest], _failed, _pending, _failed_events), do: :incomplete
  defp diagnostics_status(_missing, _failed, _pending, _failed_events), do: :complete

  defp warnings(missing, failed_results, unsafe, pending_reviews, failed_events) do
    []
    |> maybe_warn(missing != [], "Some effect intents do not have recorded results.")
    |> maybe_warn(failed_results != [], "Some effect results failed.")
    |> maybe_warn(unsafe != [], "Some unsafe_once effects are not replay-safe.")
    |> maybe_warn(pending_reviews != [], "Human review is still pending.")
    |> maybe_warn(failed_events != [], "Timeline contains failed events.")
  end

  defp maybe_warn(warnings, true, message), do: warnings ++ [message]
  defp maybe_warn(warnings, false, _message), do: warnings

  defp journal_parts(%Effect.Journal{} = journal), do: {Map.values(journal.intents), Map.values(journal.results)}

  defp journal_parts(%{intents: intents, results: results}) when is_list(intents) and is_list(results) do
    {intents, results}
  end

  defp journal_parts(%{"intents" => intents, "results" => results}) when is_list(intents) and is_list(results) do
    {intents, results}
  end

  defp journal_parts(_journal), do: {[], []}

  defp merge_intents(intents, pending_effects) when is_list(intents) and is_list(pending_effects) do
    by_id = Map.new(intents, &{map_get(&1, :id), &1})

    pending_effects
    |> Enum.reduce(by_id, fn effect, acc -> Map.put_new(acc, map_get(effect, :id), effect) end)
    |> Map.values()
  end

  defp pending_reviews(%AgentSnapshot{metadata: metadata}) do
    metadata
    |> map_get(:pending_review)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp replay_pending_effects(%Replay{snapshots: snapshots}) do
    Enum.flat_map(snapshots, fn snapshot ->
      snapshot
      |> map_get(:pending_effects, [])
      |> List.wrap()
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp failed_event?(%{} = event), do: map_get(event, :status) == :failed or map_get(event, :event) == :turn_failed
  defp failed_event?(_event), do: false

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
