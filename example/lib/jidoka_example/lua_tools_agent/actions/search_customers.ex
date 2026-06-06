defmodule JidokaExample.LuaToolsAgent.Actions.SearchCustomers do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_demo_search_customers",
    description: "Searches demo CRM customers by name, company, tags, or account status.",
    schema:
      Zoi.object(%{
        query: Zoi.string() |> Zoi.default(""),
        name: Zoi.string() |> Zoi.nullish(),
        company: Zoi.string() |> Zoi.nullish(),
        tier: Zoi.string() |> Zoi.nullish(),
        status: Zoi.string() |> Zoi.nullish(),
        tag: Zoi.string() |> Zoi.nullish(),
        value: Zoi.string() |> Zoi.nullish(),
        limit: Zoi.integer() |> Zoi.default(5)
      })

  @impl true
  def run(params, _context) do
    query = params |> query() |> String.downcase()
    limit = params |> get(:limit, 5) |> clamp_limit()

    customers =
      customers()
      |> Enum.filter(&matches?(&1, query))
      |> Enum.take(limit)

    {:ok, %{"customers" => customers, "count" => length(customers)}}
  end

  defp matches?(_customer, ""), do: true

  defp matches?(customer, query) do
    customer
    |> Map.take(["id", "name", "company", "status", "tier", "tags"])
    |> inspect()
    |> String.downcase()
    |> String.contains?(query)
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(10)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_limit(parsed)
      :error -> 5
    end
  end

  defp clamp_limit(_limit), do: 5

  defp get(params, key, default) do
    Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  defp query(params) do
    [:query, :name, :company, :tier, :status, :tag, :value]
    |> Enum.map(&get(params, &1, nil))
    |> Enum.find(&present?/1)
    |> case do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp present?(value), do: value not in [nil, ""]

  defp customers do
    [
      %{
        "id" => "cus_ada",
        "name" => "Ada Lovelace",
        "company" => "Northwind",
        "tier" => "enterprise",
        "status" => "active",
        "tags" => ["expansion", "logistics", "strategic"]
      },
      %{
        "id" => "cus_grace",
        "name" => "Grace Hopper",
        "company" => "Contoso",
        "tier" => "enterprise",
        "status" => "at_risk",
        "tags" => ["platform", "renewal", "support"]
      },
      %{
        "id" => "cus_alan",
        "name" => "Alan Turing",
        "company" => "Globex",
        "tier" => "growth",
        "status" => "active",
        "tags" => ["research", "pilot", "analytics"]
      }
    ]
  end
end
