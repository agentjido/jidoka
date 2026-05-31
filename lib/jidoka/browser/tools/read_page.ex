defmodule Jidoka.Browser.Tools.ReadPage do
  @moduledoc """
  Read a public HTTP(S) page through `jido_browser`.
  """

  use Jidoka.Action,
    name: "read_page",
    description:
      "Read a public HTTP(S) page as markdown, text, or HTML. Local and private network URLs are blocked.",
    schema:
      Zoi.object(%{
        url: Zoi.string() |> Zoi.min(1),
        selector: Zoi.string() |> Zoi.default("body"),
        format: Zoi.string() |> Zoi.default("markdown"),
        max_chars: Zoi.integer() |> Zoi.default(Jidoka.Browser.Runtime.max_content_chars())
      })

  @impl true
  def run(%{url: url} = params, context) do
    with :ok <- Jidoka.Browser.Runtime.validate_public_url(url),
         :ok <- Jidoka.Browser.Runtime.validate_allowlist(url, context, "read_page"),
         {:ok, format} <- normalize_format(Map.get(params, :format, "markdown")) do
      max_chars = Jidoka.Browser.Runtime.clamp_content_chars(Map.get(params, :max_chars))

      delegated_params =
        params
        |> Map.take([:url, :selector])
        |> Map.put(:format, format)

      case Jidoka.Browser.Runtime.delegate(
             Jidoka.Browser.Runtime.action_module(:read_page),
             delegated_params,
             context
           ) do
        {:ok, result} ->
          {:ok, Jidoka.Browser.Runtime.truncate_content(result, max_chars)}

        {:error, reason} ->
          {:error, Jidoka.Browser.Runtime.normalize_browser_error(:read_page, reason)}
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
       details: %{operation: :browser, reason: :invalid_format, cause: format}
     )}
  end
end
