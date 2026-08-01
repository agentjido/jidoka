defmodule JidokaExamples.WarrantyClaim.Agent do
  @guide """
  Review one warranty claim from a customer statement, a product photo, and a
  receipt reference. The request uses a typed tenant context. A request-time
  instruction provider adds the correct tenant policy. The runtime can retry a
  failed model, use a fallback, repair an invalid typed result, and return a
  typed claim summary.
  """
  @moduledoc @guide

  use Jidoka.Agent

  @base_instructions "Review the warranty claim from only the supplied statement, photo, receipt, and tenant policy. Return a clear decision and the required next actions."

  @context_schema Zoi.object(%{
                    claim_id: Zoi.string(),
                    plan: Zoi.enum([:standard, :premium]),
                    region: Zoi.string(),
                    tenant_id: Zoi.string()
                  })

  @result_schema Zoi.object(%{
                   claim_id: Zoi.string(),
                   confidence: Zoi.number() |> Zoi.gte(0.0) |> Zoi.lte(1.0),
                   damage_type: Zoi.enum([:accidental, :defect, :wear]),
                   decision: Zoi.enum([:approve, :manual_review, :deny]),
                   explanation: Zoi.string(),
                   required_actions: Zoi.array(Zoi.string()),
                   warranty_eligible: Zoi.boolean()
                 })

  def guide, do: @guide
  def base_instructions, do: @base_instructions
  def context_schema, do: @context_schema
  def result_schema, do: @result_schema

  agent :warranty_claim do
    model %{provider: :test, id: "warranty-static"}
    generation %{temperature: 0.0, max_tokens: 700}
    instructions @base_instructions
    context @context_schema
    result schema: @result_schema, max_repairs: 1
  end

  controls do
    max_turns 3
    timeout 10_000
  end
end
