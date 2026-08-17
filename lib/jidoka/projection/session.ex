defmodule Jidoka.Projection.Session do
  @moduledoc false

  alias Jidoka.Portable
  alias Jidoka.Projection.{Effect, Review, Turn}
  alias Jidoka.Session.{Data, Environment, Replay, Sequence}
  alias Jidoka.Snapshot

  @spec project(
          Snapshot.t()
          | Data.t()
          | Environment.t()
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
      environment: maybe_project_environment(snapshot.environment),
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
      pending_reviews: Enum.map(Data.pending_reviews(session), &Review.project/1),
      error: Portable.project(session.error),
      lease: Portable.project(session.lease),
      lineage: Portable.project(session.lineage),
      environment: maybe_project_environment(session.environment),
      metadata: Portable.project(session.metadata)
    }
  end

  def project(%Environment{} = environment) do
    %{
      version: environment.version,
      status: environment.status,
      retention: environment.retention,
      request: Jidoka.ExecutionEnvironment.project(environment.request),
      binding: Jidoka.ExecutionEnvironment.project(environment.binding),
      checkpoint: maybe_project_execution_checkpoint(environment.checkpoint),
      evidence: Jidoka.ExecutionEnvironment.project(environment.evidence)
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
      terminal: maybe_project_terminal(result.terminal),
      limits: Portable.project(result.limits)
    }
  end

  defp maybe_project_result(nil), do: nil
  defp maybe_project_result(result), do: Turn.project(result)

  defp maybe_project_snapshot(nil), do: nil
  defp maybe_project_snapshot(snapshot), do: project(snapshot)

  defp maybe_project_terminal(nil), do: nil
  defp maybe_project_terminal(terminal), do: project(terminal)

  defp maybe_project_environment(nil), do: nil
  defp maybe_project_environment(environment), do: project(environment)

  defp maybe_project_execution_checkpoint(nil), do: nil

  defp maybe_project_execution_checkpoint(checkpoint),
    do: Jidoka.ExecutionEnvironment.project(checkpoint)
end
