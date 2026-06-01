defmodule JidokaExample.ResearchAgent.Agent do
  @guide """
  Use this route to see browser-backed tools, structured output, and source
  controls running through the same Jidoka agent loop as a local action.

  Ask a focused research question. The agent should call search_web, read useful
  pages when they are accessible, then produce a short brief with source links
  instead of relying only on the model's memory.

  This example requires both an LLM key and BRAVE_SEARCH_API_KEY. It also shows
  how output controls can reject an answer that does not include sources.
  """
  @moduledoc @guide

  use Jidoka.Agent

  alias JidokaExample.ResearchAgent.Controls.RequireSources

  @research_brief_schema Zoi.object(%{
                           summary: Zoi.string(),
                           key_points: Zoi.array(Zoi.string()),
                           sources:
                             Zoi.array(
                               Zoi.object(%{
                                 title: Zoi.string(),
                                 url: Zoi.string(),
                                 note: Zoi.string()
                               })
                             )
                         })

  def guide, do: @guide

  agent :research_agent do
    instructions """
    You are a concise research brief agent.

    For every research question, call search_web once. When a useful result
    points to an accessible article, documentation page, or forum thread, call
    read_page on that URL before answering. Do not call read_page on GitHub
    repository pages; use the search result title, URL, and snippet for those
    sources. Use returned titles, URLs, snippets, and page content as your
    evidence. Prefer official docs, primary sources, or reputable technical
    references when they are available.

    Return a short answer for the user and a structured result with exactly
    these fields:

    - summary: one or two sentences.
    - key_points: three to five concise bullets.
    - sources: one to three source objects with title, url, and note.

    Every source url must come from a tool result. Do not invent citations or
    facts that are not supported by the tool results.
    """

    generation %{params: %{temperature: 0.1, max_tokens: 1100}}

    result schema: @research_brief_schema, max_repairs: 2
  end

  controls do
    max_turns 7
    timeout 60_000

    output RequireSources
  end

  tools do
    browser :public_web, mode: :read_only
  end
end
