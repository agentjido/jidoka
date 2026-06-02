defmodule JidokaExample.KitchenSinkAgent.Workflows.FeatureSummaryWorkflow do
  @moduledoc """
  Declarative deterministic workflow used by the Kitchen Sink demo.

  The parent agent chooses when to call the operation. The workflow owns the
  ordered deterministic process and returns a structured result to the agent.
  """

  use Jidoka.Workflow

  workflow do
    id(:feature_summary_workflow)
    description "Builds a deterministic feature summary from a list of feature names."

    input Zoi.object(%{
            features: Zoi.array(Zoi.string())
          })
  end

  steps do
    function :build_summary, {__MODULE__, :build_summary, 2},
      input: %{
        features: input(:features),
        tenant: context(:tenant)
      }
  end

  output from(:build_summary)

  @doc false
  @spec build_summary(map(), map()) :: {:ok, map()}
  def build_summary(%{features: features, tenant: tenant}, _context) do
    features =
      features
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    {:ok,
     %{
       feature_count: length(features),
       features: features,
       tenant: tenant,
       summary: "Deterministic workflow summarized #{length(features)} showcased features."
     }}
  end
end
