defmodule Jidoka.Debug do
  @moduledoc """
  Data-first request debug and replay diagnostics.

  `Jidoka.Debug` assembles useful debug views from values Jidoka already
  produces: turn results, sessions, snapshots, journals, events, and replay
  projections. It never calls LLMs, tools, memory stores, or runtime
  capabilities.
  """

  alias Jidoka.Debug.{ReplayDiagnostics, RequestSummary}
  alias Jidoka.Effect
  alias Jidoka.Harness
  alias Jidoka.Harness.{Replay, Session}
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc """
  Builds a request-level debug summary from a result, session, snapshot, or replay.

  The summary combines prompt debug metadata, operation results, usage,
  timeline, journal, pending reviews, and replay diagnostics. It is data-only
  and never calls runtime capabilities.
  """
  @spec request(term(), keyword()) :: {:ok, RequestSummary.t()} | {:error, term()}
  def request(target, opts \\ [])

  def request({:ok, %Turn.Result{} = result}, opts), do: request(result, opts)

  def request({:ok, %Session{} = session, %Turn.Result{} = result}, opts) do
    request(result, Keyword.put(opts, :session, session))
  end

  def request({:hibernate, %AgentSnapshot{} = snapshot}, opts), do: request(snapshot, opts)

  def request({:hibernate, %Session{} = session, %AgentSnapshot{} = snapshot}, opts) do
    request(snapshot, Keyword.put(opts, :session, session))
  end

  def request({:error, reason}, _opts), do: {:error, reason}

  def request(%Turn.Result{} = result, opts) do
    debug = debug_metadata(result)
    prompt = Map.get(debug, :prompt, %{}) || %{}
    session = Keyword.get(opts, :session)
    timeline = Jidoka.Trace.timeline(result.events, opts)

    RequestSummary.new(
      request_id: Map.get(debug, :request_id) || request_id_from_timeline(timeline),
      agent_id: Map.get(debug, :agent_id) || agent_id_from_timeline(timeline),
      session_id: session_id(session),
      status: :finished,
      model: Map.get(debug, :model) || Map.get(prompt, :model),
      input: Map.get(debug, :input),
      content: result.content,
      value: result.value,
      prompt: prompt,
      context_keys: Map.get(debug, :context_keys, []),
      operation_names: operation_names(prompt, result),
      operation_results: Enum.map(result.agent_state.operation_results, &Jidoka.project/1),
      memory: Map.get(prompt, :memory),
      usage: result.usage,
      timeline: timeline,
      journal: Jidoka.project(result.journal),
      pending_reviews: [],
      diagnostics: Map.get(debug, :diagnostics, []),
      replay_diagnostics: diagnose!(result),
      metadata: Map.drop(debug, [:prompt, :diagnostics])
    )
  end

  def request(%Session{} = session, opts) do
    request_id = Keyword.get(opts, :request_id)

    case session.result do
      %Turn.Result{} = result when is_nil(request_id) ->
        request(result, Keyword.put(opts, :session, session))

      %Turn.Result{} = result ->
        if request_id == result_request_id(result) do
          request(result, Keyword.put(opts, :session, session))
        else
          request_from_snapshot(session, request_id, opts)
        end

      _other ->
        request_from_snapshot(session, request_id, opts)
    end
  end

  def request(%AgentSnapshot{} = snapshot, opts) do
    session = Keyword.get(opts, :session)
    state = snapshot.turn_state
    prompt = prompt_debug_from_state(state)
    timeline = Jidoka.Trace.timeline(state.events, opts)

    RequestSummary.new(
      request_id: state.request.request_id,
      agent_id: snapshot.agent_id,
      session_id: session_id(session),
      status: state.status,
      model: model_from_prompt(state.prompt),
      input: state.request.input,
      content: state.result,
      value: state.result_value,
      prompt: prompt,
      context_keys: context_keys(state.request.context),
      operation_names: operation_names(prompt, state),
      operation_results: Enum.map(state.agent_state.operation_results, &Jidoka.project/1),
      memory: memory_from_prompt(state.prompt),
      usage: %{},
      timeline: timeline,
      journal: Jidoka.project(state.journal),
      pending_reviews: Enum.map(pending_reviews(snapshot), &Jidoka.project/1),
      diagnostics: state.diagnostics,
      replay_diagnostics: diagnose!(snapshot),
      metadata: snapshot.metadata
    )
  end

  def request(%Replay{} = replay, _opts) do
    RequestSummary.new(
      request_id: request_id_from_timeline(replay.timeline),
      agent_id: replay.agent_id,
      session_id: replay.session_id,
      status: replay.status,
      timeline: replay.timeline,
      journal: replay.journal,
      pending_reviews: replay.pending_reviews,
      replay_diagnostics: diagnose!(replay),
      content: replay_content(replay.result),
      value: replay_value(replay.result),
      metadata: replay.metadata
    )
  end

  def request(other, _opts), do: {:error, {:unsupported_debug_request_target, other}}

  @doc "Returns the latest request summary for a session."
  @spec latest(Session.t(), keyword()) :: {:ok, RequestSummary.t()} | {:error, term()}
  def latest(%Session{} = session, opts \\ []), do: request(session, opts)

  @doc """
  Diagnoses replayable runtime data without executing effects.

  Diagnostics flag missing effect results, failed effect results, unsafe
  effects, pending reviews, and failed timeline events.
  """
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
      pending_reviews: replay.pending_reviews,
      metadata: %{source: :replay, session_id: replay.session_id}
    )
  end

  def diagnose(%Effect.Journal{} = journal) do
    diagnostics_from_parts(journal: journal, events: [], pending_reviews: [], metadata: %{source: :journal})
  end

  def diagnose(other), do: {:error, {:unsupported_replay_diagnostics_target, other}}

  defp diagnose!(target) do
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

  defp request_from_snapshot(%Session{} = session, nil, opts) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot -> request(snapshot, Keyword.put(opts, :session, session))
      nil -> request_from_session_data(session, nil, opts)
    end
  end

  defp request_from_snapshot(%Session{} = session, request_id, opts) do
    snapshot =
      Enum.find(session.snapshots, fn %AgentSnapshot{} = snapshot ->
        snapshot.turn_state.request.request_id == request_id
      end)

    case snapshot do
      %AgentSnapshot{} = snapshot -> request(snapshot, Keyword.put(opts, :session, session))
      nil -> request_from_session_data(session, request_id, opts)
    end
  end

  defp request_from_session_data(%Session{} = session, request_id, _opts) do
    request = session_request(session, request_id)

    if is_nil(request) and is_binary(request_id) do
      {:error, {:request_debug_not_found, session.session_id, request_id}}
    else
      request_summary_from_session_data(session, request)
    end
  end

  defp request_summary_from_session_data(%Session{} = session, request) do
    RequestSummary.new(
      request_id: request_id(request),
      agent_id: session.agent_id,
      session_id: session.session_id,
      status: session.status,
      input: request_input(request),
      context_keys: request_context_keys(request),
      pending_reviews: Enum.map(session.pending_reviews, &Jidoka.project/1),
      error: session.error,
      replay_diagnostics: diagnose!(session),
      metadata: session.metadata
    )
  end

  defp session_request(%Session{requests: requests}, nil), do: List.last(requests)

  defp session_request(%Session{requests: requests}, request_id) when is_binary(request_id) do
    Enum.find(requests, &(request_id(&1) == request_id))
  end

  defp debug_metadata(%Turn.Result{metadata: metadata}) do
    case map_get(metadata, :debug) do
      %{} = debug -> atomize_known_debug(debug)
      _other -> %{}
    end
  end

  defp atomize_known_debug(%{} = debug) do
    %{
      request_id: map_get(debug, :request_id),
      agent_id: map_get(debug, :agent_id),
      model: map_get(debug, :model),
      input: map_get(debug, :input),
      context_keys: map_get(debug, :context_keys, []),
      prompt: map_get(debug, :prompt, %{}),
      diagnostics: map_get(debug, :diagnostics, []),
      started_at_ms: map_get(debug, :started_at_ms)
    }
  end

  defp prompt_debug_from_state(%Turn.State{prompt: nil}), do: %{}

  defp prompt_debug_from_state(%Turn.State{prompt: %{} = prompt}) do
    %{
      model: map_get(prompt, :model),
      loop_index: map_get(prompt, :loop_index),
      messages: map_get(prompt, :messages, []),
      message_count: length(map_get(prompt, :messages, [])),
      operations: map_get(prompt, :operations, []),
      operation_names: Enum.map(map_get(prompt, :operations, []), &map_get(&1, :name)),
      operation_count: length(map_get(prompt, :operations, [])),
      result: map_get(prompt, :result),
      memory: map_get(prompt, :memory),
      generation: map_get(prompt, :generation)
    }
  end

  defp model_from_prompt(%{} = prompt), do: map_get(prompt, :model)
  defp model_from_prompt(_prompt), do: nil

  defp memory_from_prompt(%{} = prompt), do: map_get(prompt, :memory)
  defp memory_from_prompt(_prompt), do: nil

  defp operation_names(%{} = prompt, %Turn.Result{} = result) do
    prompt_names = prompt |> map_get(:operation_names, []) |> Enum.reject(&is_nil/1)

    result_names =
      result.agent_state.operation_results
      |> Enum.map(& &1.operation)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(prompt_names ++ result_names)
  end

  defp operation_names(%{} = prompt, %Turn.State{} = state) do
    prompt_names = prompt |> map_get(:operation_names, []) |> Enum.reject(&is_nil/1)

    result_names =
      state.agent_state.operation_results
      |> Enum.map(& &1.operation)
      |> Enum.reject(&is_nil/1)

    Enum.uniq(prompt_names ++ result_names)
  end

  defp operation_names(_prompt, _result), do: []

  defp result_request_id(%Turn.Result{} = result) do
    result
    |> debug_metadata()
    |> Map.get(:request_id)
  end

  defp request_id(%Turn.Request{request_id: request_id}), do: request_id
  defp request_id(_request), do: nil

  defp request_input(%Turn.Request{input: input}), do: input
  defp request_input(_request), do: nil

  defp request_context_keys(%Turn.Request{context: context}), do: context_keys(context)
  defp request_context_keys(_request), do: []

  defp request_id_from_timeline(timeline), do: Enum.find_value(timeline, &map_get(&1, :request_id))
  defp agent_id_from_timeline(timeline), do: Enum.find_value(timeline, &map_get(&1, :agent_id))

  defp pending_reviews(%AgentSnapshot{metadata: metadata}) do
    metadata
    |> map_get(:pending_review)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp session_id(%Session{session_id: session_id}), do: session_id
  defp session_id(_session), do: nil

  defp context_keys(%{} = context) do
    context
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp context_keys(_context), do: []

  defp failed_event?(%{} = event), do: map_get(event, :status) == :failed or map_get(event, :event) == :turn_failed
  defp failed_event?(_event), do: false

  defp replay_content(%{content: content}) when is_binary(content), do: content
  defp replay_content(%{"content" => content}) when is_binary(content), do: content
  defp replay_content(_result), do: nil

  defp replay_value(%{} = result), do: map_get(result, :value)
  defp replay_value(_result), do: nil

  defp map_get(map, key, default \\ nil)

  defp map_get(%{} = map, key, default) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
