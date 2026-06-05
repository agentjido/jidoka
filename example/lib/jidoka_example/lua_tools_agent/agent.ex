defmodule JidokaExample.LuaToolsAgent.Agent do
  @guide """
  This example demonstrates dynamic scripting over a constrained host capability surface.

  The agent only sees three Jidoka tools: query, describe, and execute. The
  execute step runs a short sandboxed Lua script that can call several hidden
  read-only host actions, then returns the script result plus a trace of each
  hidden action call.

  Use this when a normal handful of tools is not enough, but you still want the
  host application to decide what capabilities are visible, allowed, and traced.
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

    You have a Lua tool layer for a hidden read-only backoffice surface.
    Do not guess hidden function names.

    For backoffice tasks:
    1. Call lua_tools_query to find relevant hidden capabilities.
    2. Call lua_tools_describe with the smallest useful set of ids.
    3. Call lua_tools_execute with a short Lua script that composes those capabilities.

    Prefer scripts that call multiple host functions when that reduces model/tool
    round trips. Keep scripts short, deterministic, and read-only. After execution,
    summarize what happened and include the script result, hidden_call_count,
    hidden_tools_used, and takeaways in the structured result.

    For the default unpaid-invoice follow-up task, the Lua script must:
    - search customers with crm.customer.search;
    - iterate over search.customers, not over the search map itself;
    - list unpaid invoices for each customer with billing.invoice.list_unpaid;
    - draft each follow-up with support.note.draft_followup;
    - return the customer, invoices, and drafted note for each matching customer.

    The support note call shape is:
    support.note.draft_followup({
      customer_name = customer.name,
      company = customer.company,
      invoice_count = invoices.count,
      total_due_cents = invoices.total_due_cents
    })

    Do not synthesize a note in Lua if support.note.draft_followup is available.
    """

    generation %{params: %{temperature: 0.0, max_tokens: 1_200}}

    result schema: @lua_result_schema, max_repairs: 2
  end

  controls do
    max_turns 8
    timeout 45_000
  end

  tools do
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsQuery
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe
    action JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute
  end
end
