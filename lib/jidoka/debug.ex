defmodule Jidoka.Debug do
  @moduledoc """
  Data-first request debug and replay diagnostics.

  `Jidoka.Debug` assembles useful debug views from values Jidoka already
  produces: turn results, sessions, snapshots, journals, events, and replay
  projections. It never calls LLMs, tools, memory stores, or runtime
  capabilities.

  Use this module after a turn when you need one value that explains the
  request: prompt messages, selected operations, operation results, usage,
  timeline, journal, pending reviews, and replay diagnostics.

      {:ok, result} = Jidoka.turn(MyApp.Agent, "Check order A1001")
      {:ok, summary} = Jidoka.Debug.request(result)

      summary.prompt.messages
      summary.operation_results
      summary.usage
      summary.replay_diagnostics.status

  Request summaries accept:

  - `Jidoka.Turn.Result` for a completed turn;
  - `Jidoka.Harness.Session` for the latest request, or a specific
    `request_id:`;
  - `Jidoka.Runtime.AgentSnapshot` for hibernated work;
  - `Jidoka.Harness.Replay` for stored replay projections;
  - common return tuples such as `{:ok, result}` and `{:hibernate, snapshot}`.

  `Jidoka.Debug` intentionally stores context keys, not full context values.
  Keep secrets and large application payloads in your application data, not in
  debug summaries.

  Replay diagnostics use four statuses:

  - `:complete` - all recorded effect intents have results;
  - `:waiting` - human review is pending;
  - `:failed` - an effect result or timeline event failed;
  - `:incomplete` - at least one effect intent has no recorded result.
  """

  alias Jidoka.Debug.{Diagnostics, ReplayDiagnostics, RequestSummary}
  alias Jidoka.Harness.{Replay, Session}
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  @doc """
  Builds a request-level debug summary from a result, session, snapshot, or replay.

  The summary combines prompt debug metadata, operation results, usage,
  timeline, journal, pending reviews, and replay diagnostics. It is data-only
  and never calls runtime capabilities.

  Options:

  - `:session` - attach a session id when summarizing a snapshot or result;
  - `:request_id` - when the target is a session, select a specific stored
    request or snapshot. Unknown ids return
    `{:error, {:request_debug_not_found, session_id, request_id}}`.
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
      replay_diagnostics: Diagnostics.diagnose!(result),
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
      context_keys: context_keys(Jidoka.Context.data(state.request.context)),
      operation_names: operation_names(prompt, state),
      operation_results: Enum.map(state.agent_state.operation_results, &Jidoka.project/1),
      memory: memory_from_prompt(state.prompt),
      usage: %{},
      timeline: timeline,
      journal: Jidoka.project(state.journal),
      pending_reviews: Enum.map(pending_reviews(snapshot), &Jidoka.project/1),
      diagnostics: state.diagnostics,
      replay_diagnostics: Diagnostics.diagnose!(snapshot),
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
      replay_diagnostics: Diagnostics.diagnose!(replay),
      content: replay_content(replay.result),
      value: replay_value(replay.result),
      metadata: replay.metadata
    )
  end

  def request(other, _opts), do: {:error, {:unsupported_debug_request_target, other}}

  @doc """
  Returns the latest request summary for a session.

  This is a convenience wrapper around `request/2`. Pass `request_id:` to
  select a specific request in the session history.
  """
  @spec latest(Session.t(), keyword()) :: {:ok, RequestSummary.t()} | {:error, term()}
  def latest(%Session{} = session, opts \\ []), do: request(session, opts)

  @doc """
  Diagnoses replayable runtime data without executing effects.

  Diagnostics flag missing effect results, failed effect results, unsafe
  effects, pending reviews, and failed timeline events.

  Use this when you have a session, snapshot, replay, result, or journal and
  need to know whether the recorded data is complete enough to inspect or
  replay safely.
  """
  @spec diagnose(term()) :: {:ok, ReplayDiagnostics.t()} | {:error, term()}
  def diagnose(target), do: Diagnostics.diagnose(target)

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
      replay_diagnostics: Diagnostics.diagnose!(session),
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

  defp request_context_keys(%Turn.Request{context: %Jidoka.Context{} = context}),
    do: context_keys(Jidoka.Context.data(context))

  defp request_context_keys(%Turn.Request{context: context}), do: context_keys(context)
  defp request_context_keys(_request), do: []

  defp request_id_from_timeline(timeline), do: Enum.find_value(timeline, &map_get(&1, :request_id))
  defp agent_id_from_timeline(timeline), do: Enum.find_value(timeline, &map_get(&1, :agent_id))

  defp session_id(%Session{session_id: session_id}), do: session_id
  defp session_id(_session), do: nil

  defp context_keys(%{} = context) do
    context
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp context_keys(_context), do: []

  defp pending_reviews(%AgentSnapshot{metadata: metadata}) do
    metadata
    |> map_get(:pending_review)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

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
