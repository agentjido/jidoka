defmodule JidokaExampleWeb.Markdown do
  @moduledoc false

  @options [
    extension: [
      autolink: true,
      strikethrough: true,
      table: true,
      tasklist: true
    ],
    render: [
      unsafe: false
    ]
  ]

  def render(content) do
    content
    |> to_string()
    |> normalize_llm_links()
    |> MDEx.to_html(@options)
    |> case do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _reason} -> Phoenix.HTML.html_escape(content)
    end
  end

  defp normalize_llm_links(content) do
    String.replace(content, ~r/\]\s+\((https?:\/\/[^)\s]+)\)/, "](\\1)")
  end
end
