defmodule JidokaExamples.GovernedTools.ScriptedLLM do
  @moduledoc false

  alias Jidoka.Effect

  @catalog_script """
  return jidoka.workflow({
    id = "governed_source_search",
    steps = {
      {id = "search", tool = "research.source.search", arguments = {query = "Jidoka", limit = 2}}
    },
    output = "search"
  })
  """

  def skill_round_trip do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case result_count(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "research_policy_lookup",
             arguments: %{"topic" => "Jidoka tool safety"}
           }}

        1 ->
          {:ok,
           %{
             type: :final,
             content: "Use approved public sources and cite the source URL."
           }}
      end
    end
  end

  def catalog_round_trip do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case result_count(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "catalog_query",
             arguments: %{"query" => "research source"}
           }}

        1 ->
          {:ok,
           %{
             type: :operation,
             name: "catalog_describe",
             arguments: %{"ids" => ["research.source.search"]}
           }}

        2 ->
          {:ok,
           %{
             type: :operation,
             name: "catalog_execute",
             arguments: %{
               "allowed_tools" => ["research.source.search"],
               "script" => @catalog_script
             }
           }}

        3 ->
          {:ok,
           %{
             type: :final,
             content: "The approved catalog returned two Jidoka documentation sources."
           }}
      end
    end
  end

  def browser_round_trip do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case result_count(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "read_page",
             arguments: %{
               "format" => "text",
               "max_chars" => 500,
               "url" => "https://docs.example.com/guides/tools-and-operations"
             }
           }}

        1 ->
          {:ok,
           %{
             type: :final,
             content: "Jidoka tools use typed schemas, explicit controls, and deterministic effects."
           }}
      end
    end
  end

  def final(content) do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: content}} end
  end

  defp result_count(%Effect.Journal{} = journal, kind) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == kind end)
  end
end
