defmodule Jidoka.Session.Replay do
  @moduledoc """
  Inspection-friendly replay projection for stored session data.

  Replay is data-only. It reconstructs what is already known from sessions,
  snapshots, journals, and events; it never calls runtime capabilities.
  """

  alias Jidoka.Event
  alias Jidoka.Projection.Effect, as: EffectProjection
  alias Jidoka.Projection.Review, as: ReviewProjection
  alias Jidoka.Projection.Turn, as: TurnProjection
  alias Jidoka.Portable
  alias Jidoka.Session.Data
  alias Jidoka.Snapshot
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              session_revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              agent_id: Schema.non_empty_string(),
              status: Schema.atom_enum(Data.statuses()) |> Zoi.nullish(),
              snapshots: Zoi.array(Zoi.map()) |> Zoi.default([]),
              timeline: Zoi.array(Zoi.map()) |> Zoi.default([]),
              journal: Zoi.map() |> Zoi.default(%{intents: [], results: []}),
              pending_reviews: Zoi.array(Zoi.map()) |> Zoi.default([]),
              result: Zoi.map() |> Zoi.nullish(),
              lineage: Zoi.map() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for replay data."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds replay data from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds replay data and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "session replay")

  @doc "Builds replay data from a durable session."
  @spec from_session(Data.t()) :: {:ok, t()} | {:error, term()}
  def from_session(%Data{} = session) do
    new(
      session_id: session.session_id,
      session_revision: session.revision,
      agent_id: session.agent_id,
      status: session.status,
      snapshots: Enum.map(session.snapshots, &snapshot_summary/1),
      timeline: timeline(session),
      journal: latest_journal(session),
      pending_reviews: Enum.map(Data.pending_reviews(session), &ReviewProjection.project/1),
      result: project_result(session.result),
      lineage: project_lineage(session.lineage),
      metadata: session.metadata
    )
  end

  @doc "Builds replay data from a hibernation snapshot."
  @spec from_snapshot(Snapshot.t()) :: {:ok, t()} | {:error, term()}
  def from_snapshot(%Snapshot{} = snapshot) do
    new(
      agent_id: snapshot.agent_id,
      snapshots: [snapshot_summary(snapshot)],
      timeline: timeline([snapshot.turn_state], nil),
      journal: EffectProjection.project(snapshot.turn_state.journal),
      pending_reviews: pending_reviews(snapshot),
      metadata: snapshot.metadata
    )
  end

  defp snapshot_summary(%Snapshot{} = snapshot) do
    %{
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: TurnProjection.project(snapshot.cursor),
      status: snapshot.turn_state.status,
      loop_index: snapshot.turn_state.loop_index,
      pending_effects: Enum.map(snapshot.turn_state.pending_effects, &EffectProjection.project/1)
    }
  end

  defp timeline(%Data{} = session), do: timeline(snapshot_states(session), session.result)

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

  defp latest_journal(%Data{result: %Turn.Result{} = result}),
    do: EffectProjection.project(result.journal)

  defp latest_journal(%Data{} = session) do
    case Data.latest_snapshot(session) do
      %Snapshot{} = snapshot -> EffectProjection.project(snapshot.turn_state.journal)
      nil -> %{intents: [], results: []}
    end
  end

  defp project_result(%Turn.Result{} = result), do: TurnProjection.project(result)
  defp project_result(nil), do: nil

  defp project_lineage(nil), do: nil
  defp project_lineage(lineage), do: Portable.project(lineage)

  defp snapshot_states(%Data{snapshots: snapshots}), do: Enum.map(snapshots, & &1.turn_state)

  defp pending_reviews(%Snapshot{} = snapshot),
    do: Enum.map(Data.pending_reviews(snapshot), &ReviewProjection.project/1)
end
