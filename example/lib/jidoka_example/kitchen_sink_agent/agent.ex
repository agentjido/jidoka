defmodule JidokaExample.KitchenSinkAgent.Agent do
  @guide """
  This route combines the stable Jidoka V2 features into one supervised agent.

  Run the default prompt to exercise typed agent context, memory, local
  actions, skills, subagents, handoffs, Ash resource tools, browser search,
  catalog lookup, structured output, input controls, output controls,
  streaming, and the activity projection in one place.

  For the human-review path, ask it to refund order B2002 for $25. The same
  agent will hibernate before the refund operation, then resume after you
  approve or reject the pending action.

  V2 does not bring forward a hook DSL. The Kitchen Sink route shows the
  replacement shape: input, operation, and output controls around the same
  Runic-backed turn spine.
  """
  @moduledoc @guide

  use Jidoka.Agent

  alias JidokaExample.ApprovalAgent.Agent, as: ApprovalAgent
  alias JidokaExample.ApprovalAgent.Controls.RequireRefundApproval
  alias JidokaExample.KitchenSinkAgent.Controls.AllowSpecialistHandoff
  alias JidokaExample.KitchenSinkAgent.Controls.BlockInternalPrompt
  alias JidokaExample.KitchenSinkAgent.Controls.RequireShowcaseSummary
  alias JidokaExample.KitchenSinkAgent.Skills.ShowcaseSkill
  alias JidokaExample.KitchenSinkAgent.Subagents.EvidenceAgent
  alias JidokaExample.KitchenSinkAgent.Workflows.FeatureSummaryWorkflow

  @context_schema Zoi.object(%{
                    tenant: Zoi.string() |> Zoi.default("demo"),
                    channel: Zoi.string() |> Zoi.default("kitchen_sink"),
                    session_id: Zoi.string() |> Zoi.nullish(),
                    surface: Zoi.string() |> Zoi.default("phoenix_live_view"),
                    example: Zoi.string() |> Zoi.default("kitchen_sink_agent"),
                    actor:
                      Zoi.object(%{
                        id: Zoi.string(),
                        role: Zoi.string() |> Zoi.default("developer")
                      })
                      |> Zoi.default(%{id: "demo-actor", role: "developer"})
                  })

  @showcase_result_schema Zoi.object(%{
                            summary: Zoi.string(),
                            features:
                              Zoi.array(
                                Zoi.object(%{
                                  name: Zoi.string(),
                                  evidence: Zoi.string()
                                })
                              ),
                            sources:
                              Zoi.array(
                                Zoi.object(%{
                                  title: Zoi.string(),
                                  url: Zoi.string(),
                                  note: Zoi.string()
                                })
                              )
                              |> Zoi.default([]),
                            next_steps: Zoi.array(Zoi.string()) |> Zoi.default([])
                          })

  def guide, do: @guide

  agent :kitchen_sink_agent do
    instructions """
    You are the Jidoka Kitchen Sink showcase agent.

    Use tools for observable behavior and only summarize results that tools
    actually returned. Keep responses concise and structured for inspection.

    For the showcase prompt, run the requested operations in order:
    showcase_policy_lookup, mcp_showcase_notes, evidence_specialist,
    refund_specialist, build_feature_summary, remember preferences,
    show_context, lookup_order, enrich_lead, score_lead, list_customers,
    catalog_jido_actions, search_web, and read_page when an accessible
    non-GitHub source is useful.

    Use create_customer once per distinct customer name. Customer names must be
    unique. If create_customer reports a duplicate, say the record already
    exists.

    For refunds, call issue_refund with order_id, amount, and reason. Do not
    claim the refund was issued until the tool result is present; the operation
    may pause for human review.

    Always return a structured result with summary, exercised features, browser
    sources when available, and one to three next steps. Never describe a tool as
    ready, prepared, planned, or initiated in the feature summary.
    """

    context @context_schema

    generation %{params: %{temperature: 0.0, max_tokens: 1_600}}

    memory %{scope: :session, max_entries: 50}

    result schema: @showcase_result_schema, max_repairs: 2
  end

  controls do
    max_turns 18
    timeout 90_000

    input BlockInternalPrompt
    operation RequireRefundApproval, when: [kind: :action, name: "issue_refund"]
    operation AllowSpecialistHandoff, when: [kind: :handoff, name: "refund_specialist"]
    output RequireShowcaseSummary
  end

  tools do
    skill ShowcaseSkill

    subagent EvidenceAgent,
      as: :evidence_specialist,
      description: "Delegates one bounded evidence-checking task to a child Jidoka agent.",
      forward_context: {:only, [:tenant, :channel, :session_id, :surface, :example]},
      result: :structured

    handoff ApprovalAgent,
      as: :refund_specialist,
      description: "Records that future refund follow-up should route to the approval agent.",
      forward_context: {:only, [:tenant, :channel, :session_id, :surface, :example]},
      metadata: %{demo: "kitchen_sink"}

    workflow FeatureSummaryWorkflow,
      as: :build_feature_summary,
      description: "Runs deterministic workflow code to summarize the showcased features.",
      forward_context: {:only, [:tenant, :session_id]},
      result: :structured

    action JidokaExample.KitchenSinkAgent.Actions.ShowContext
    action JidokaExample.SupportAgent.Actions.LookupOrder
    action JidokaExample.LeadQualityAgent.Actions.EnrichLead
    action JidokaExample.LeadQualityAgent.Actions.ScoreLead
    action JidokaExample.MemoryAgent.Actions.RememberPreference
    action JidokaExample.ApprovalAgent.Actions.IssueRefund

    ash_resource JidokaExample.AshAgent.Resources.Customer,
      actions: [:create_customer, :list_customers]

    browser :public_web, mode: :read_only
    catalog :jido_actions, via: :jido_discovery, max_results: 8

    mcp_tools endpoint: :kitchen_sink_mcp,
              prefix: "mcp_",
              tools: [
                %{
                  name: "showcase_notes",
                  description: "Returns MCP-hosted notes for the Kitchen Sink demo.",
                  input_schema: %{
                    "type" => "object",
                    "properties" => %{"topic" => %{"type" => "string"}}
                  }
                }
              ]
  end
end
