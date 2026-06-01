defmodule Jidoka.Harness.Replay do
  @moduledoc """
  Inspection-friendly replay projection for stored harness data.

  Replay is data-only. It reconstructs what is already known from sessions,
  snapshots, journals, and events; it never calls runtime capabilities.
  """

  alias Jidoka.Event
  alias Jidoka.Harness.Session
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              agent_id: Schema.non_empty_string(),
              status: Schema.atom_enum(Session.statuses()) |> Zoi.nullish(),
              snapshots: Zoi.array(Zoi.map()) |> Zoi.default([]),
              timeline: Zoi.array(Zoi.map()) |> Zoi.default([]),
              journal: Zoi.map() |> Zoi.default(%{intents: [], results: []}),
              pending_reviews: Zoi.array(Zoi.map()) |> Zoi.default([]),
              result: Zoi.map() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "harness replay")

  @spec from_session(Session.t()) :: {:ok, t()} | {:error, term()}
  def from_session(%Session{} = session) do
    new(
      session_id: session.session_id,
      agent_id: session.agent_id,
      status: session.status,
      snapshots: Enum.map(session.snapshots, &snapshot_summary/1),
      timeline: timeline(session),
      journal: latest_journal(session),
      pending_reviews: Enum.map(session.pending_reviews, &Jidoka.project/1),
      result: project_result(session.result),
      metadata: session.metadata
    )
  end

  @spec from_snapshot(AgentSnapshot.t()) :: {:ok, t()} | {:error, term()}
  def from_snapshot(%AgentSnapshot{} = snapshot) do
    new(
      agent_id: snapshot.agent_id,
      snapshots: [snapshot_summary(snapshot)],
      timeline: timeline([snapshot.turn_state], nil),
      journal: Jidoka.project(snapshot.turn_state.journal),
      pending_reviews: pending_reviews(snapshot),
      metadata: snapshot.metadata
    )
  end

  defp snapshot_summary(%AgentSnapshot{} = snapshot) do
    %{
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: Jidoka.project(snapshot.cursor),
      status: snapshot.turn_state.status,
      loop_index: snapshot.turn_state.loop_index,
      pending_effects: Enum.map(snapshot.turn_state.pending_effects, &Jidoka.project/1)
    }
  end

  defp timeline(%Session{} = session), do: timeline(snapshot_states(session), session.result)

  defp timeline(states, %Turn.Result{} = result) when is_list(states) do
    states
    |> Enum.flat_map(& &1.events)
    |> Kernel.++(result.events)
    |> unique_events()
    |> Jidoka.Trace.timeline()
  end

  defp timeline(states, nil) when is_list(states) do
    states
    |> Enum.flat_map(& &1.events)
    |> unique_events()
    |> Jidoka.Trace.timeline()
  end

  defp unique_events(events) do
    Enum.uniq_by(events, fn %Event{} = event ->
      {event.request_id, event.seq, event.event, event.effect_id, event.operation}
    end)
  end

  defp latest_journal(%Session{result: %Turn.Result{} = result}),
    do: Jidoka.project(result.journal)

  defp latest_journal(%Session{} = session) do
    case Session.latest_snapshot(session) do
      %AgentSnapshot{} = snapshot -> Jidoka.project(snapshot.turn_state.journal)
      nil -> %{intents: [], results: []}
    end
  end

  defp project_result(%Turn.Result{} = result), do: Jidoka.project(result)
  defp project_result(nil), do: nil

  defp snapshot_states(%Session{snapshots: snapshots}), do: Enum.map(snapshots, & &1.turn_state)

  defp pending_reviews(%AgentSnapshot{} = snapshot) do
    snapshot.metadata
    |> Map.get("pending_review", Map.get(snapshot.metadata, :pending_review))
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Jidoka.project/1)
  end
end
