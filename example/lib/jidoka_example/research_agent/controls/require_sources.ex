defmodule JidokaExample.ResearchAgent.Controls.RequireSources do
  @moduledoc false

  use Jidoka.Control, name: "require_sources"

  @impl true
  def call(%{boundary: :output, result_value: %{sources: sources}}) when is_list(sources) do
    if Enum.any?(sources, &valid_source?/1) do
      :allow
    else
      {:block, :missing_research_sources}
    end
  end

  def call(%{boundary: :output}), do: {:block, :missing_research_sources}
  def call(_context), do: :allow

  defp valid_source?(%{url: url}) when is_binary(url), do: valid_url?(url)
  defp valid_source?(%{"url" => url}) when is_binary(url), do: valid_url?(url)
  defp valid_source?(_source), do: false

  defp valid_url?(url), do: String.starts_with?(url, ["http://", "https://"])
end
