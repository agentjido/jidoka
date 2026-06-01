defmodule JidokaExample.KitchenSinkAgent.MCP.LocalClient do
  @moduledoc false

  def list_tools(:kitchen_sink_mcp, _opts) do
    {:ok,
     %{
       data: %{
         "tools" => [
           %{
             "name" => "showcase_notes",
             "description" => "Returns MCP-hosted notes for the Kitchen Sink demo.",
             "inputSchema" => %{
               "type" => "object",
               "properties" => %{"topic" => %{"type" => "string"}}
             }
           }
         ]
       }
     }}
  end

  def call_tool(:kitchen_sink_mcp, "showcase_notes", arguments, _opts) do
    topic = Map.get(arguments, "topic") || Map.get(arguments, :topic) || "parity"

    {:ok,
     %{
       data: %{
         "topic" => topic,
         "note" =>
           "This result came through the MCP operation source and was recorded as a normal Jidoka operation observation.",
         "evidence" => [
           "MCP tool metadata compiled into Agent.Spec.operations",
           "the operation was planned by the LLM decision protocol",
           "the tool result was appended to durable agent state"
         ]
       }
     }}
  end
end
