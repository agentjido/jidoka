defmodule JidokaExample.ResearchAgent.Agent do
  @guide """
  The Research Agent is the second rung in the example ladder: a supervised
  agent with browser-backed tools and stricter run controls.

  Ask a focused research question. The agent should search the web, read one or
  two useful pages, then answer with source links instead of relying only on the
  model's memory.

  This example requires both an LLM key and BRAVE_SEARCH_API_KEY because it uses
  the browser tool surface.
  """
  @moduledoc @guide

  use Jidoka.Agent

  def guide, do: @guide

  agent :research_agent do
    instructions """
    You are a concise research agent.

    For every research question, call search_web once, then call read_page on
    one or two useful result URLs before answering. Use the returned titles,
    URLs, snippets, and page content as your evidence. Do not invent citations
    or facts that are not supported by the tool results.

    Answer with a short summary and include source links from the search
    results when they are available.
    """

    generation %{params: %{temperature: 0.1, max_tokens: 900}}
  end

  controls do
    max_turns 6
    timeout 45_000
  end

  tools do
    browser :public_web, mode: :read_only
  end
end
