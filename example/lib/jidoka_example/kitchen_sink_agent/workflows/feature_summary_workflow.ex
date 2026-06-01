defmodule JidokaExample.KitchenSinkAgent.Workflows.FeatureSummaryWorkflow do
  @moduledoc """
  Deterministic workflow used by the Kitchen Sink demo.

  This demonstrates workflow-as-tool: the parent agent chooses when to call the
  operation, while application code owns the deterministic process and output.
  """

  use Jidoka.Workflow,
    id: :feature_summary_workflow,
    description: "Builds a deterministic feature summary from a list of feature names.",
    parameters_schema: %{
      "type" => "object",
      "properties" => %{
        "features" => %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      },
      "required" => ["features"]
    }

  @impl true
  def run(input, context) do
    features =
      input
      |> get(:features, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    {:ok,
     %{
       feature_count: length(features),
       features: features,
       tenant: get(context, :tenant),
       summary: "Deterministic workflow summarized #{length(features)} showcased features."
     }}
  end

  defp get(map, key, default \\ nil)

  defp get(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
