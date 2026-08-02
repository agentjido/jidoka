defmodule Jidoka.Projection do
  @moduledoc """
  Stable public projections for Jidoka data contracts.

  This module is a public dispatcher. Each architecture area owns its
  projection rules in `Jidoka.Projection.*`.
  """

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Handoff
  alias Jidoka.Projection
  alias Jidoka.Review
  alias Jidoka.Session.{Data, Replay}
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.Workflow

  @doc "Projects a supported Jidoka data contract into a stable value."
  @spec project(term()) :: term()
  def project(%Agent.Spec{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Generation{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Result{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Memory{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Operation{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Controls{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Controls.Input{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Controls.Output{} = value), do: Projection.AgentSpec.project(value)
  def project(%Agent.Spec.Controls.Operation{} = value), do: Projection.AgentSpec.project(value)

  def project(%Agent.State{} = value), do: Projection.Agent.project(value)
  def project(%Agent.Message{} = value), do: Projection.Agent.project(value)
  def project(%Handoff{} = value), do: Projection.Agent.project(value)

  def project(%Turn.Plan{} = value), do: Projection.Turn.project(value)
  def project(%Turn.Request{} = value), do: Projection.Turn.project(value)
  def project(%Turn.State{} = value), do: Projection.Turn.project(value)
  def project(%Turn.Cursor{} = value), do: Projection.Turn.project(value)
  def project(%Turn.Result{} = value), do: Projection.Turn.project(value)

  def project(%Effect.Journal{} = value), do: Projection.Effect.project(value)
  def project(%Effect.Intent{} = value), do: Projection.Effect.project(value)
  def project(%Effect.LLMDecision{} = value), do: Projection.Effect.project(value)
  def project(%Effect.OperationRequest{} = value), do: Projection.Effect.project(value)
  def project(%Effect.OperationResult{} = value), do: Projection.Effect.project(value)
  def project(%Effect.Result{} = value), do: Projection.Effect.project(value)

  def project(%Jidoka.Memory.Entry{} = value), do: Projection.Memory.project(value)
  def project(%Jidoka.Memory.RecallRequest{} = value), do: Projection.Memory.project(value)
  def project(%Jidoka.Memory.RecallResult{} = value), do: Projection.Memory.project(value)
  def project(%Jidoka.Memory.WriteRequest{} = value), do: Projection.Memory.project(value)
  def project(%Jidoka.Memory.WriteResult{} = value), do: Projection.Memory.project(value)

  def project(%Snapshot{} = value), do: Projection.Session.project(value)
  def project(%Data{} = value), do: Projection.Session.project(value)
  def project(%Replay{} = value), do: Projection.Session.project(value)

  def project(%Review.Interrupt{} = value), do: Projection.Review.project(value)
  def project(%Review.Request{} = value), do: Projection.Review.project(value)
  def project(%Review.Response{} = value), do: Projection.Review.project(value)

  def project(%Workflow.Spec{} = value), do: Projection.Workflow.project(value)
  def project(%Workflow.Step{} = value), do: Projection.Workflow.project(value)

  def project(%Jidoka.Debug.RequestSummary{} = value), do: Projection.Observability.project(value)
  def project(%Jidoka.Debug.ReplayDiagnostics{} = value), do: Projection.Observability.project(value)
  def project(%Jidoka.Trace.Policy{} = value), do: Projection.Observability.project(value)
  def project(%Jidoka.Eval.Case{} = value), do: Projection.Observability.project(value)
  def project(%Jidoka.Eval.Run{} = value), do: Projection.Observability.project(value)
  def project(%Event{} = value), do: Projection.Observability.project(value)

  def project(value), do: Jidoka.Portable.project(value)
end
