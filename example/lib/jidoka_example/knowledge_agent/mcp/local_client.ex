defmodule JidokaExample.KnowledgeAgent.MCP.LocalClient do
  @moduledoc false

  def list_tools(:knowledge_mcp, _opts) do
    {:ok,
     %{
       data: %{
         "tools" => [
           %{
             "name" => "docs_note",
             "description" => "Returns an MCP-hosted implementation note for a Jidoka topic.",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{"topic" => %{"type" => "string"}}
             }
           }
         ]
       }
     }}
  end

  def call_tool(:knowledge_mcp, "docs_note", arguments, _opts) do
    topic = Map.get(arguments, "topic") || Map.get(arguments, :topic) || "jidoka"

    {:ok,
     %{
       data: %{
         "topic" => topic,
         "note" =>
           "This note came from the Knowledge Agent MCP client and was executed through the same Jidoka operation effect path as local tools.",
         "recommended_use" =>
           "Use MCP for tool catalogs or external servers that should remain outside the application codebase."
       }
     }}
  end
end
