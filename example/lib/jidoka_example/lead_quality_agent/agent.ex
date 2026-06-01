defmodule JidokaExample.LeadQualityAgent.Agent do
  @guide """
  This example demonstrates a multi-tool decision path with structured output.

  Ask whether a lead is worth pursuing. The agent should enrich the lead first,
  score the enriched profile second, then return a structured qualification
  summary that the UI can render without scraping text.

  This is still a thin Jidoka loop: the domain-specific behavior lives in Jido
  actions, while controls bound the run and the result schema validates the
  final answer shape.
  """
  @moduledoc @guide

  use Jidoka.Agent

  @lead_result_schema Zoi.object(%{
                        company: Zoi.string(),
                        score: Zoi.integer(),
                        grade: Zoi.string(),
                        recommendation: Zoi.string(),
                        reasons: Zoi.array(Zoi.string())
                      })

  def guide, do: @guide

  agent :lead_quality_agent do
    instructions """
    You are a lead qualification agent.

    When the user asks about a lead, call enrich_lead first. Then call
    score_lead using the enriched firmographic fields. Do not score a lead
    directly from the user's wording.

    After both tool calls, answer plainly and return a structured result with:
    company, score, grade, recommendation, and reasons.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 900}}

    result schema: @lead_result_schema, max_repairs: 2
  end

  controls do
    max_turns 6
    timeout 30_000
  end

  tools do
    action JidokaExample.LeadQualityAgent.Actions.EnrichLead
    action JidokaExample.LeadQualityAgent.Actions.ScoreLead
  end
end
