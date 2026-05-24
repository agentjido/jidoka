defmodule Jidoka.Web.Tools.ReadPage do
  @moduledoc """
  Read a public HTTP(S) page through `jido_browser`.
  """

  use Jidoka.Action,
    name: "read_page",
    description: "Read a public HTTP(S) page as markdown, text, or HTML. Local and private network URLs are blocked.",
    schema:
      Zoi.object(%{
        url: Zoi.string() |> Zoi.min(1),
        selector: Zoi.string() |> Zoi.default("body"),
        format: Zoi.string() |> Zoi.default("markdown"),
        max_chars: Zoi.integer() |> Zoi.default(Jidoka.Web.Config.max_content_chars())
      }),
    output_schema:
      Zoi.object(%{
        url: Zoi.string(),
        content: Zoi.string(),
        format: Zoi.any()
      })

  @impl true
  def run(%{url: url} = params, context) do
    with :ok <- Jidoka.Web.Runtime.validate_public_url(url),
         {:ok, format} <- normalize_format(Map.get(params, :format, "markdown")) do
      max_chars = Jidoka.Web.Runtime.clamp_content_chars(Map.get(params, :max_chars))

      delegated_params =
        params
        |> Map.take([:url, :selector])
        |> Map.put(:format, format)

      case Jido.Browser.Actions.ReadPage.run(delegated_params, context) do
        {:ok, result} ->
          {:ok, Jidoka.Web.Runtime.truncate_content(result, max_chars)}

        {:error, reason} ->
          {:error, Jidoka.Web.Runtime.normalize_browser_error(:read_page, reason)}
      end
    end
  end

  defp normalize_format(format) when format in [:markdown, :text, :html], do: {:ok, format}
  defp normalize_format("markdown"), do: {:ok, :markdown}
  defp normalize_format("text"), do: {:ok, :text}
  defp normalize_format("html"), do: {:ok, :html}

  defp normalize_format(format) do
    {:error,
     Jidoka.Error.validation_error("format must be markdown, text, or html.",
       field: :format,
       value: format,
       details: %{operation: :web, reason: :invalid_format, cause: format}
     )}
  end
end
