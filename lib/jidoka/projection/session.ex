defmodule Jidoka.Projection.Session do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Projection.{Review, Turn}
  alias Jidoka.Session.{Data, Replay}
  alias Jidoka.Snapshot

  @spec project(Snapshot.t() | Data.t() | Replay.t()) :: map()
  def project(%Snapshot{} = snapshot) do
    %{
      schema_version: snapshot.schema_version,
      snapshot_id: snapshot.snapshot_id,
      agent_id: snapshot.agent_id,
      cursor: Turn.project(snapshot.cursor),
      turn_state: Turn.project(snapshot.turn_state),
      metadata: Portable.project(snapshot.metadata)
    }
  end

  def project(%Data{} = session) do
    %{
      schema_version: session.schema_version,
      revision: session.revision,
      session_id: session.session_id,
      agent_id: session.agent_id,
      status: session.status,
      requests: Enum.map(session.requests, &Turn.project/1),
      snapshots: Enum.map(session.snapshots, &project/1),
      result: maybe_project_result(session.result),
      pending_reviews: Enum.map(session.pending_reviews, &Review.project/1),
      error: Portable.project(session.error),
      lease: Portable.project(session.lease),
      lineage: Portable.project(session.lineage),
      metadata: Portable.project(session.metadata)
    }
  end

  def project(%Replay{} = replay), do: replay |> Map.from_struct() |> Portable.project()

  defp maybe_project_result(nil), do: nil
  defp maybe_project_result(result), do: Turn.project(result)
end
