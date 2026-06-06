defmodule JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_tools_describe",
    description: "Returns exact workflow step specs for selected hidden host capabilities.",
    schema:
      Zoi.object(%{
        ids: Zoi.array(Zoi.string())
      })

  alias JidokaExample.LuaToolsAgent.Catalog

  @impl true
  def run(params, _context) do
    ids = params |> get(:ids, []) |> List.wrap() |> Enum.map(&to_string/1)

    with {:ok, tools} <- Catalog.describe(ids) do
      {:ok,
       ids
       |> base_result(tools)
       |> maybe_put_portfolio_template()}
    end
  end

  defp get(params, key, default),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))

  defp base_result(ids, tools) do
    %{
      "tools" => tools,
      "allowed_tools" => ids,
      "notice" =>
        "Catalog metadata only. No hidden host tool has run yet. The next required step is lua_tools_execute.",
      "next" =>
        "Call lua_tools_execute with a short script that starts with return jidoka.workflow({...}). Use selected ids as step tool values. Do not call hidden tools as Lua globals. Step outputs are JSON maps directly; they are not wrapped in a result field."
    }
  end

  defp maybe_put_portfolio_template(%{"allowed_tools" => ids} = result) do
    required =
      MapSet.new([
        "crm.customer.search",
        "billing.invoice.list_unpaid",
        "support.note.draft_followup"
      ])

    if MapSet.subset?(required, MapSet.new(ids)) do
      Map.put(result, "template", portfolio_template())
    else
      result
    end
  end

  defp portfolio_template do
    """
    return jidoka.workflow({
      id = "portfolio_followup",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {tier = "enterprise", limit = 10}
        },
        {
          id = "invoices",
          map = {
            over = {from = "search", path = {"customers"}},
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
          id = "invoice_count",
          reduce = {
            over = {from = "invoices", path = {"items"}},
            mode = "sum",
            path = {"count"}
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
            invoice_count = {from = "invoice_count", path = {"value"}},
            total_due_cents = {from = "total_due", path = {"value"}}
          }
        }
      },
      output = {
        total_due_cents = {from = "total_due", path = {"value"}},
        invoice_count = {from = "invoice_count", path = {"value"}},
        follow_up = {from = "note"}
      }
    })
    """
  end
end
