defmodule Jidoka.Web.Tools.SearchWeb do
  @moduledoc """
  Search the public web through `jido_browser`'s Brave Search action.
  """

  use Jidoka.Action,
    name: "search_web",
    description: "Search the public web and return a small set of title, URL, and snippet results.",
    schema:
      Zoi.object(%{
        query: Zoi.string() |> Zoi.min(1),
        max_results: Zoi.integer() |> Zoi.default(Jidoka.Web.Config.max_results()),
        country: Zoi.string() |> Zoi.default("us"),
        search_lang: Zoi.string() |> Zoi.default("en"),
        freshness: Zoi.string() |> Zoi.optional()
      }),
    output_schema:
      Zoi.object(%{
        query: Zoi.string(),
        results: Zoi.list(Zoi.map()),
        count: Zoi.integer()
      })

  @impl true
  def run(%{query: query} = params, context) do
    delegated_params =
      params
      |> Map.put(:query, String.trim(query))
      |> Map.update(:max_results, Jidoka.Web.Config.max_results(), &Jidoka.Web.Runtime.clamp_search_results/1)

    case Jido.Browser.Actions.SearchWeb.run(delegated_params, context) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, Jidoka.Web.Runtime.normalize_browser_error(:search_web, reason)}
    end
  end
end
