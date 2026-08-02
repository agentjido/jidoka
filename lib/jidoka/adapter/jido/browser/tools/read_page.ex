defmodule Jidoka.Adapter.Jido.Browser.Tools.ReadPage do
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
        max_chars: Zoi.integer() |> Zoi.default(Jidoka.Adapter.Jido.Browser.max_content_chars())
      })

  @impl true
  def run(%{url: url} = params, context) do
    with :ok <- Jidoka.Adapter.Jido.Browser.validate_public_url(url),
         :ok <- Jidoka.Adapter.Jido.Browser.validate_allowlist(url, context, "read_page"),
         {:ok, format} <- normalize_format(Map.get(params, :format, "markdown")) do
      max_chars = Jidoka.Adapter.Jido.Browser.clamp_content_chars(Map.get(params, :max_chars))

      delegated_params =
        params
        |> Map.take([:url, :selector])
        |> Map.put(:format, format)

      case Jidoka.Adapter.Jido.Browser.delegate(
             Jidoka.Adapter.Jido.Browser.action_module(:read_page),
             delegated_params,
             context
           ) do
        {:ok, result} ->
          {:ok, Jidoka.Adapter.Jido.Browser.truncate_content(result, max_chars)}

        {:error, reason} ->
          {:error, Jidoka.Adapter.Jido.Browser.normalize_browser_error(:read_page, reason)}
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
