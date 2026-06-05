defmodule JidokaExample.LuaToolsAgent.Agent do
  @guide """
  This example demonstrates `Jidoka.Workflow.Lua`: a governed Lua scripting
  layer that lets an agent author a bounded workflow plan over a constrained
  host capability catalog.

  The agent only sees three Jidoka tools: query, describe, and execute. The
  execute step runs a short sandboxed Lua script. That script can only return a
  `jidoka.workflow({...})` plan; Jidoka validates and executes the hidden
  read-only host actions, then returns the workflow result plus a trace of each
  hidden action call.

  Use this when direct one-by-one tool calling is too rigid, but the host
  application still needs to control what capabilities are visible, allowed,
  bounded, and traced.
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
    The only Lua host API is jidoka.workflow({...}). Hidden tools are never Lua globals.
    Do not guess hidden tool ids.

    For tasks that need scripting:
    1. Call lua_tools_query to find relevant hidden capabilities.
    2. Call lua_tools_describe with the smallest useful set of ids.
    3. Call lua_tools_execute with a short Lua script that returns jidoka.workflow({...}).
       Pass allowed_tools with exactly the ids you described.

    The Lua execution API is jidoka.workflow({...}). Keep scripts short,
    deterministic, and read-only. After execution, summarize what happened and
    include the script result, hidden_call_count, hidden_tools_used, and
    takeaways in the structured result.

    Workflow steps support:
    - direct tool steps with tool and arguments
    - map steps for bounded fan-out over a list of items
    - reduce steps for deterministic fan-in with collect, count, sum, or first
    - gate steps for boolean checks that can drive when on later steps

    Independent root steps and map items run in parallel through Runic.
    Dependent steps use {from = "step_id", path = {...}} refs. Map arguments
    can use {var = "item", path = {...}} refs, or a custom variable name set by
    as = "customer".

    Prefer map when applying the same hidden tool to a list of customers or
    invoices. Prefer reduce when combining map outputs. Use gate plus when for
    follow-up steps that should only run above a threshold.

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

    A bounded map/reduce/gate shape is:
    jidoka.workflow({
      id = "portfolio_followup",
      steps = {
        {
          id = "invoices",
          map = {
            over = {
              {id = "cus_ada", name = "Ada Lovelace"},
              {id = "cus_grace", name = "Grace Hopper"}
            },
            as = "customer",
            tool = "billing.invoice.list_unpaid",
            arguments = {customer_id = {var = "customer", path = {"id"}}},
            max_items = 10,
            max_concurrency = 4
          }
        },
        {
          id = "total_due",
          reduce = {
            over = {from = "invoices", path = {"items"}},
            mode = "sum",
            path = {"total_due_cents"}
          }
        },
        {
          id = "large_balance",
          gate = {
            op = "gt",
            left = {from = "total_due", path = {"value"}},
            right = 100000
          }
        },
        {
          id = "note",
          tool = "support.note.draft_followup",
          when = {from = "large_balance", path = {"passed"}},
          arguments = {
            customer_name = "Portfolio Team",
            company = "ExampleCo",
            invoice_count = {from = "invoices", path = {"count"}},
            total_due_cents = {from = "total_due", path = {"value"}}
          }
        }
      },
      output = {total = {from = "total_due", path = {"value"}}, note = {from = "note"}}
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
