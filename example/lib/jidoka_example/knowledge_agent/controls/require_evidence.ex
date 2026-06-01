defmodule JidokaExample.KnowledgeAgent.Controls.RequireEvidence do
  @moduledoc false

  use Jidoka.Control, name: "require_knowledge_evidence"

  @impl true
  def call(%{boundary: :output, result_value: %{evidence: evidence}}) when is_list(evidence) do
    require_evidence(evidence)
  end

  def call(%{boundary: :output, result_value: %{"evidence" => evidence}})
      when is_list(evidence) do
    require_evidence(evidence)
  end

  def call(%{boundary: :output}), do: {:block, :missing_knowledge_evidence}
  def call(_context), do: :allow

  defp require_evidence(evidence) do
    if Enum.any?(evidence, &valid_evidence?/1) do
      :allow
    else
      {:block, :missing_knowledge_evidence}
    end
  end

  defp valid_evidence?(%{tool: tool, summary: summary}),
    do: filled?(tool) and filled?(summary)

  defp valid_evidence?(%{"tool" => tool, "summary" => summary}),
    do: filled?(tool) and filled?(summary)

  defp valid_evidence?(_entry), do: false

  defp filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled?(_value), do: false
end
