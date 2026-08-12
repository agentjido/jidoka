defmodule Jidoka.Projection.Session do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Projection.{Effect, Review, Turn}
  alias Jidoka.Session.{Data, Replay, Sequence}
  alias Jidoka.Snapshot

  @spec project(
          Snapshot.t()
          | Data.t()
          | Replay.t()
          | Sequence.Step.t()
          | Sequence.Terminal.t()
          | Sequence.Result.t()
        ) :: map()
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

  def project(%Sequence.Step{} = step) do
    %{
      index: step.index,
      request: Turn.project(step.request),
      result: Turn.project(step.result),
      operation_results: Enum.map(step.operation_results, &Effect.project/1)
    }
  end

  def project(%Sequence.Terminal{} = terminal) do
    %{
      kind: terminal.kind,
      index: terminal.index,
      request_id: terminal.request_id,
      reason: Portable.project(terminal.reason),
      snapshot: maybe_project_snapshot(terminal.snapshot),
      cancellation: Portable.project(terminal.cancellation)
    }
  end

  def project(%Sequence.Result{} = result) do
    %{
      status: result.status,
      session: project(result.session),
      steps: Enum.map(result.steps, &project/1),
      terminal: maybe_project_terminal(result.terminal)
    }
  end

  defp maybe_project_result(nil), do: nil
  defp maybe_project_result(result), do: Turn.project(result)

  defp maybe_project_snapshot(nil), do: nil
  defp maybe_project_snapshot(snapshot), do: project(snapshot)

  defp maybe_project_terminal(nil), do: nil
  defp maybe_project_terminal(terminal), do: project(terminal)
end
