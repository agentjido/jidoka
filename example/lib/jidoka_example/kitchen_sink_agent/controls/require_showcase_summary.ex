defmodule JidokaExample.KitchenSinkAgent.Controls.RequireShowcaseSummary do
  @moduledoc false

  use Jidoka.Control, name: "require_showcase_summary"

  @impl true
  def call(%{boundary: :output, result_value: %{features: features}}) when is_list(features) do
    require_features(features)
  end

  def call(%{boundary: :output, result_value: %{"features" => features}})
      when is_list(features) do
    require_features(features)
  end

  def call(%{boundary: :output}), do: {:block, :missing_showcase_features}
  def call(_context), do: :allow

  defp require_features(features) do
    if Enum.any?(features, &feature_entry?/1) do
      :allow
    else
      {:block, :missing_showcase_features}
    end
  end

  defp feature_entry?(%{name: name}) when is_binary(name), do: String.trim(name) != ""
  defp feature_entry?(%{"name" => name}) when is_binary(name), do: String.trim(name) != ""
  defp feature_entry?(_feature), do: false
end
