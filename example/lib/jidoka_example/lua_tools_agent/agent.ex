defmodule JidokaExample.LuaToolsAgent.Agent do
  @guide """
  This example demonstrates a governed Lua scripting layer over a constrained
  host capability catalog.

  The agent only sees three Jidoka tools: query, describe, and execute. The
  execute step runs a short sandboxed Lua script that defines a small
  Lua-authored workflow over hidden read-only host actions, then returns the
  workflow result plus a trace of each hidden action call.

  Use this when a normal handful of direct tool calls is not enough, but you
  still want the host application to decide what capabilities are visible,
  allowed, and traced.
  """
  @moduledoc @guide

  use Jidoka.Agent

  @lua_result_schema Zoi.object(%{
                       summary: Zoi.string(),
                       script_result: Zoi.any() |> Zoi.nullish(),
                       hidden_call_count: Zoi.integer(),
                       hidden_tools_used: Zoi.array(Zoi.string()),
                       takeaways: Zoi.array(Zoi.string())
                     })

  def guide, do: @guide

  agent :lua_tools_agent do
    instructions """
    You are a dynamic scripting demo agent for Jidoka.

    You have a governed Lua scripting layer for hidden read-only host capabilities.
    Do not guess hidden function names.

    For tasks that need scripting:
    1. Call lua_tools_query to find relevant hidden capabilities.
    2. Call lua_tools_describe with the smallest useful set of ids.
    3. Call lua_tools_execute with a short Lua script that returns jidoka.workflow({...}).

    The Lua execution API is jidoka.workflow({...}). Independent root steps run in
    parallel through Runic; dependent steps use {from = "step_id", path = {...}}
    refs. Keep scripts short, deterministic, and read-only. After execution,
    summarize what happened and include the script result, hidden_call_count,
    hidden_tools_used, and takeaways in the structured result.

    If lua_tools_execute returns a validation or execution error, revise the Lua
    script and call lua_tools_execute again with a simpler workflow. Do not keep
    retrying the same failed script.

    The workflow call shape is:
    jidoka.workflow({
      id = "invoice_followup",
      retries = 1,
      steps = {
        {id = "search", tool = "crm.customer.search", arguments = {query = "Northwind", limit = 1}},
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = {from = "search", path = {"customers", 1, "id"}}}
        }
      },
      output = "invoices"
    })

    For independent parallel roots, put multiple steps with no dependencies in
    the same workflow. Do not call hidden functions directly; use jidoka.workflow
    only.

    Do not synthesize a note in Lua if support.note.draft_followup is available.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 1_200}}

    result schema: @lua_result_schema, max_repairs: 2
  end

  tools do
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsQuery
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute
  end

  controls do
    max_turns 8
    timeout 45_000
  end
end
