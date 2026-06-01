defmodule JidokaExample.KitchenSinkAgent.Subagents.EvidenceAgent do
  @moduledoc """
  Bounded child agent used by the Kitchen Sink demo.

  It shows Jidoka subagents as callable operations: the parent delegates a
  narrow task, the child runs one normal Jidoka turn, and the result flows back
  into the parent turn without transferring ownership.
  """

  use Jidoka.Agent

  @evidence_schema Zoi.object(%{
                     answer: Zoi.string(),
                     assumptions: Zoi.array(Zoi.string()) |> Zoi.default([]),
                     next_check: Zoi.string() |> Zoi.nullish()
                   })

  agent :kitchen_sink_evidence_agent do
    instructions """
    You are a bounded evidence specialist for a parent Jidoka showcase agent.

    Answer only the delegated task. Be concise. If the task asks for feature
    evidence, identify what the parent should cite and any assumption it should
    avoid overstating.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 500}}

    result schema: @evidence_schema, max_repairs: 1
  end
end
