defmodule JidokaExample.LeadQualityAgent.Actions.EnrichLead do
  @moduledoc false

  use Jidoka.Action,
    name: "enrich_lead",
    description: "Enriches a sales lead with deterministic firmographic details.",
    schema:
      Zoi.object(%{
        name: Zoi.string(),
        company: Zoi.string(),
        email: Zoi.string() |> Zoi.nullish()
      })

  @impl true
  def run(params, _context) do
    company = params |> get(:company) |> normalize_company()
    profile = Map.get(profiles(), company, default_profile(company))

    {:ok,
     Map.merge(profile, %{
       "lead_name" => get(params, :name),
       "company" => display_company(company),
       "email" => get(params, :email)
     })}
  end

  defp get(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp normalize_company(nil), do: "unknown"

  defp normalize_company(company) do
    company
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp display_company("unknown"), do: "Unknown"

  defp display_company(company) do
    company
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp default_profile(company) do
    %{
      "industry" => "general business",
      "company_size" => "51-200",
      "budget_signal" => "unknown",
      "urgency_signal" => "medium",
      "fit_notes" => "No account history found for #{display_company(company)}."
    }
  end

  defp profiles do
    %{
      "northwind" => %{
        "industry" => "logistics",
        "company_size" => "201-500",
        "budget_signal" => "active evaluation",
        "urgency_signal" => "high",
        "fit_notes" => "Asked for implementation timing and security review."
      },
      "contoso" => %{
        "industry" => "manufacturing",
        "company_size" => "1001-5000",
        "budget_signal" => "approved project",
        "urgency_signal" => "high",
        "fit_notes" => "Existing CRM migration project with executive sponsor."
      },
      "globex" => %{
        "industry" => "retail",
        "company_size" => "51-200",
        "budget_signal" => "research only",
        "urgency_signal" => "low",
        "fit_notes" => "Downloaded comparison guide, no active buying motion."
      }
    }
  end
end
