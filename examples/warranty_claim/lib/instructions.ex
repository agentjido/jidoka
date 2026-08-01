defmodule JidokaExamples.WarrantyClaim.Instructions do
  @moduledoc false

  @behaviour Jidoka.Instructions

  @impl true
  def resolve(base, context) do
    with {:ok, region_policy} <- region_policy(context.data.region),
         {:ok, plan_policy} <- plan_policy(context.data.plan) do
      {:ok,
       Enum.join(
         [
           base,
           "Tenant: #{context.data.tenant_id}.",
           "Claim: #{context.data.claim_id}.",
           region_policy,
           plan_policy,
           "Use manual_review when the evidence is missing or not clear."
         ],
         "\n"
       )}
    end
  end

  defp region_policy("US"), do: {:ok, "Apply the United States warranty policy."}
  defp region_policy("EU"), do: {:ok, "Apply the European Union warranty policy."}
  defp region_policy(region), do: {:error, {:unsupported_warranty_region, region}}

  defp plan_policy(:premium) do
    {:ok, "The premium plan covers accidental damage when a receipt and a product photo are present."}
  end

  defp plan_policy(:standard), do: {:ok, "The standard plan covers manufacturing defects only."}
end
