defmodule Jidoka.Browser.Tools.SnapshotUrl do
  @moduledoc """
  Return an LLM-friendly read-only page snapshot through `jido_browser`.
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
        max_content_length: Zoi.integer() |> Zoi.default(Jidoka.Browser.Runtime.max_content_chars())
      })

  @impl true
  def run(%{url: url} = params, context) do
    with :ok <- Jidoka.Browser.Runtime.validate_public_url(url),
         :ok <- Jidoka.Browser.Runtime.validate_allowlist(url, context, "snapshot_url") do
      max_content_length =
        params
        |> Map.get(:max_content_length)
        |> Jidoka.Browser.Runtime.clamp_content_chars()

      delegated_params =
        params
        |> Map.take([:url, :selector, :include_links, :include_headings, :include_forms])
        |> Map.put(:max_content_length, max_content_length)

      case Jidoka.Browser.Runtime.delegate(
             Jidoka.Browser.Runtime.action_module(:snapshot_url),
             delegated_params,
             context
           ) do
        {:ok, result} ->
          {:ok, Jidoka.Browser.Runtime.truncate_content(result, max_content_length)}

        {:error, reason} ->
          {:error, Jidoka.Browser.Runtime.normalize_browser_error(:snapshot_url, reason)}
      end
    end
  end
end
