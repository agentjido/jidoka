defmodule JidokaExample.LeadQualityAgent.Actions.ScoreLead do
  @moduledoc false

  use Jidoka.Action,
    name: "score_lead",
    description: "Scores an enriched sales lead and recommends the next sales motion.",
    schema:
      Zoi.object(%{
        company: Zoi.string(),
        industry: Zoi.string(),
        company_size: Zoi.string(),
        budget_signal: Zoi.string(),
        urgency_signal: Zoi.string(),
        fit_notes: Zoi.string() |> Zoi.nullish()
      })

  @impl true
  def run(params, _context) do
    score =
      35
      |> add(size_points(get(params, :company_size)))
      |> add(budget_points(get(params, :budget_signal)))
      |> add(urgency_points(get(params, :urgency_signal)))
      |> min(100)

    {:ok,
     %{
       "company" => get(params, :company),
       "score" => score,
       "grade" => grade(score),
       "recommended_action" => recommended_action(score),
       "reasons" => reasons(params)
     }}
  end

  defp get(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key), ""))
  defp add(score, points), do: score + points

  defp size_points("1001-5000"), do: 20
  defp size_points("201-500"), do: 15
  defp size_points("51-200"), do: 8
  defp size_points(_size), do: 4

  defp budget_points("approved project"), do: 25
  defp budget_points("active evaluation"), do: 20
  defp budget_points("research only"), do: 5
  defp budget_points(_signal), do: 8

  defp urgency_points("high"), do: 20
  defp urgency_points("medium"), do: 10
  defp urgency_points(_signal), do: 3

  defp grade(score) when score >= 85, do: "A"
  defp grade(score) when score >= 70, do: "B"
  defp grade(score) when score >= 50, do: "C"
  defp grade(_score), do: "D"

  defp recommended_action(score) when score >= 85, do: "Route to sales today."
  defp recommended_action(score) when score >= 70, do: "Book discovery this week."
  defp recommended_action(score) when score >= 50, do: "Send nurture sequence."
  defp recommended_action(_score), do: "Keep in low-touch nurture."

  defp reasons(params) do
    [
      "Industry: #{get(params, :industry)}",
      "Company size: #{get(params, :company_size)}",
      "Budget signal: #{get(params, :budget_signal)}",
      "Urgency signal: #{get(params, :urgency_signal)}",
      get(params, :fit_notes)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
