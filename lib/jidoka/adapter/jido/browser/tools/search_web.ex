defmodule Jidoka.Adapter.Jido.Browser.Tools.SearchWeb do
  @moduledoc """
  Search the public web through `jido_browser`.
  """

  use Jidoka.Action,
    name: "search_web",
    description: "Search the public web and return title, URL, and snippet results.",
    schema:
      Zoi.object(%{
        query: Zoi.string() |> Zoi.min(1),
        max_results: Zoi.integer() |> Zoi.default(Jidoka.Adapter.Jido.Browser.max_results()),
        country: Zoi.string() |> Zoi.default("us"),
        search_lang: Zoi.string() |> Zoi.default("en"),
        freshness: Zoi.string() |> Zoi.optional()
      })

  @impl true
  def run(%{query: query} = params, context) do
    delegated_params =
      params
      |> Map.put(:query, String.trim(query))
      |> Map.update(
        :max_results,
        Jidoka.Adapter.Jido.Browser.max_results(),
        &Jidoka.Adapter.Jido.Browser.clamp_search_results/1
      )

    case Jidoka.Adapter.Jido.Browser.delegate(
           Jidoka.Adapter.Jido.Browser.action_module(:search_web),
           delegated_params,
           context
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, Jidoka.Adapter.Jido.Browser.normalize_browser_error(:search_web, reason)}
    end
  end
end
