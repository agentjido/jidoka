defmodule Jidoka.Web.Tools.SnapshotUrl do
  @moduledoc """
  Return an LLM-friendly read-only snapshot of a public HTTP(S) page.
  """

  use Jidoka.Action,
    name: "snapshot_url",
    description:
      "Inspect a public HTTP(S) page and return content, links, and headings. Local and private network URLs are blocked.",
    schema:
      Zoi.object(%{
        url: Zoi.string() |> Zoi.min(1),
        selector: Zoi.string() |> Zoi.default("body"),
        include_links: Zoi.boolean() |> Zoi.default(true),
        include_headings: Zoi.boolean() |> Zoi.default(true),
        include_forms: Zoi.boolean() |> Zoi.default(false),
        max_content_length: Zoi.integer() |> Zoi.default(Jidoka.Web.Config.max_content_chars())
      }),
    output_schema: Zoi.map()

  @impl true
  def run(%{url: url} = params, context) do
    with :ok <- Jidoka.Web.Runtime.validate_public_url(url) do
      max_content_length =
        params
        |> Map.get(:max_content_length)
        |> Jidoka.Web.Runtime.clamp_content_chars()

      delegated_params =
        params
        |> Map.take([:url, :selector, :include_links, :include_headings, :include_forms])
        |> Map.put(:max_content_length, max_content_length)

      case Jido.Browser.Actions.SnapshotUrl.run(delegated_params, context) do
        {:ok, result} ->
          {:ok, Jidoka.Web.Runtime.truncate_content(result, max_content_length)}

        {:error, reason} ->
          {:error, Jidoka.Web.Runtime.normalize_browser_error(:snapshot_url, reason)}
      end
    end
  end
end
