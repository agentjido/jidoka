defmodule Jidoka.Workflow.LuaTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Catalog
  alias Jidoka.Workflow.Lua
  alias Jidoka.Workflow.Lua.Plan.Spec.Helpers

  defmodule SearchCustomers do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_search_customers",
      description: "Searches test customers.",
      schema: Zoi.object(%{query: Zoi.string() |> Zoi.default(""), limit: Zoi.integer() |> Zoi.default(5)})

    @impl true
    def run(params, _context) do
      query = params |> get(:query, "") |> to_string() |> String.downcase()
      limit = params |> get(:limit, 5) |> clamp_limit()

      customers =
        [
          %{"id" => "cus_ada", "name" => "Ada Lovelace", "company" => "Northwind"},
          %{"id" => "cus_grace", "name" => "Grace Hopper", "company" => "Contoso"}
        ]
        |> Enum.filter(&(query == "" or String.contains?(String.downcase(inspect(&1)), query)))
        |> Enum.take(limit)

      {:ok, %{"customers" => customers, "count" => length(customers)}}
    end

    defp get(params, key, default), do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
    defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(10)
    defp clamp_limit(_limit), do: 5
  end

  defmodule ListInvoices do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_list_invoices",
      description: "Lists test invoices.",
      schema: Zoi.object(%{customer_id: Zoi.string(), limit: Zoi.integer() |> Zoi.default(5)})

    @impl true
    def run(params, _context) do
      customer_id = params |> get(:customer_id, "") |> to_string()

      invoices =
        %{
          "cus_ada" => [%{"id" => "inv_ada", "amount_cents" => 42_500}],
          "cus_grace" => [%{"id" => "inv_grace", "amount_cents" => 132_000}]
        }
        |> Map.get(customer_id, [])

      {:ok,
       %{
         "customer_id" => customer_id,
         "invoices" => invoices,
         "count" => length(invoices),
         "total_due_cents" => Enum.reduce(invoices, 0, &(&1["amount_cents"] + &2))
       }}
    end

    defp get(params, key, default), do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  defmodule DraftNote do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_draft_note",
      description: "Drafts a test note.",
      schema:
        Zoi.object(%{
          customer_name: Zoi.string(),
          company: Zoi.string(),
          invoice_count: Zoi.integer(),
          total_due_cents: Zoi.integer()
        })

    @impl true
    def run(params, _context) do
      {:ok,
       %{
         "note" =>
           "#{get(params, :customer_name, "Customer")} at #{get(params, :company, "Unknown")} owes #{get(params, :total_due_cents, 0)} cents."
       }}
    end

    defp get(params, key, default), do: Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  defmodule MutatingAction do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_mutating_action",
      description: "Mutates state.",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context), do: {:ok, %{"mutated" => true}}
  end

  test "requires a catalog or entries" do
    assert {:error, :missing_lua_workflow_catalog} = Lua.execute("return {}")
  end

  test "Lua plan helpers normalize known atom and string keys without creating atoms" do
    known_keys = [
      "after",
      "arguments",
      "args",
      "depends_on",
      "as",
      "gate",
      "id",
      "left",
      "map",
      "max_concurrency",
      "max_items",
      "mode",
      "name",
      "op",
      "output",
      "over",
      "path",
      "reduce",
      "retries",
      "right",
      "steps",
      "tool",
      "tool_id",
      "when"
    ]

    for key <- known_keys do
      atom_key = String.to_existing_atom(key)
      assert Helpers.known_value(%{atom_key => :atom_value}, key, :missing) == :atom_value
      assert Helpers.known_value(%{key => :string_value}, key, :missing) == :string_value
      assert Helpers.has_known_key?(%{atom_key => true}, key)
      assert Helpers.has_known_key?(%{key => true}, key)
    end

    refute Helpers.has_known_key?(%{}, "id")
    assert Helpers.known_value(%{}, "id", :missing) == :missing

    assert Helpers.clamp_retries(-1) == 0
    assert Helpers.clamp_retries(9) == 2
    assert Helpers.clamp_retries("2") == 2
    assert Helpers.clamp_retries("bad") == 0
    assert Helpers.clamp_retries(:bad) == 0

    assert Helpers.clamp_max_items(0) == 1
    assert Helpers.clamp_max_items(99) == 25
    assert Helpers.clamp_max_items("7") == 7
    assert Helpers.clamp_max_items("bad") == 10
    assert Helpers.clamp_max_items(:bad) == 10

    assert Helpers.clamp_max_concurrency(0) == 1
    assert Helpers.clamp_max_concurrency(99) == 16
    assert Helpers.clamp_max_concurrency("7") == 7
    assert Helpers.clamp_max_concurrency("bad") == 8
    assert Helpers.clamp_max_concurrency(:bad) == 8
  end

  test "executes a Lua-authored workflow against catalog entries" do
    script = """
    return jidoka.workflow({
      id = "invoice_followup",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Northwind", limit = 1}
        },
        {
          id = "invoices",
          tool = "billing.invoice.list",
          arguments = {
            customer_id = {from = "search", path = {"customers", 1, "id"}},
            limit = 5
          }
        },
        {
          id = "note",
          tool = "support.note.draft",
          arguments = {
            customer_name = {from = "search", path = {"customers", 1, "name"}},
            company = {from = "search", path = {"customers", 1, "company"}},
            invoice_count = {from = "invoices", path = {"count"}},
            total_due_cents = {from = "invoices", path = {"total_due_cents"}}
          }
        }
      },
      output = "note"
    })
    """

    assert {:ok, result} = Lua.execute(script, catalog: catalog())
    assert result["status"] == "completed"
    assert result["call_count"] == 3
    assert result["result"]["workflow_id"] == "invoice_followup"
    assert result["result"]["output"]["note"] =~ "Ada Lovelace"
  end

  test "requires the script to return the workflow result" do
    script = """
    jidoka.workflow({
      id = "not_returned",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Northwind", limit = 1}
        }
      },
      output = "search"
    })
    """

    assert {:error, result} = Lua.execute(script, catalog: catalog())
    assert result["status"] == "failed"
    assert result["reason"] == "Lua script must return jidoka.workflow({...})."
    assert result["result"] == []
    assert result["call_count"] == 1
  end

  test "supports map, reduce, gate, and conditional downstream steps" do
    script = """
    return jidoka.workflow({
      id = "portfolio",
      steps = {
        {
          id = "invoices",
          map = {
            over = {
              {id = "cus_ada"},
              {id = "cus_grace"}
            },
            as = "customer",
            tool = "billing.invoice.list",
            arguments = {customer_id = {var = "customer", path = {"id"}}}
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
            right = 200000
          }
        },
        {
          id = "note",
          tool = "support.note.draft",
          when = {from = "large_balance", path = {"passed"}},
          arguments = {
            customer_name = "Portfolio",
            company = "ExampleCo",
            invoice_count = {from = "invoices", path = {"count"}},
            total_due_cents = {from = "total_due", path = {"value"}}
          }
        }
      },
      output = {
        total = {from = "total_due", path = {"value"}},
        gate = {from = "large_balance", path = {"passed"}},
        note = {from = "note"}
      }
    })
    """

    assert {:ok, result} = Lua.execute(script, catalog: catalog())
    assert result["status"] == "completed"
    assert result["call_count"] == 2
    assert result["result"]["output"]["total"] == 174_500
    assert result["result"]["output"]["gate"] == false
    assert result["result"]["output"]["note"] == %{"reason" => "condition_false", "status" => "skipped"}
  end

  test "rejects mutating tools by default" do
    assert {:error, {:lua_tool_not_read_only, "admin.mutate"}} =
             Lua.execute("return {}", catalog: catalog(), allowed_tools: ["admin.mutate"])
  end

  defp catalog do
    Catalog.new!(id: "workflow-lua-test", name: "Workflow Lua Test")
    |> Catalog.register!(SearchCustomers,
      id: "crm.customer.search",
      description: "Search customers",
      visibility: :hidden,
      read_only?: true
    )
    |> Catalog.register!(ListInvoices,
      id: "billing.invoice.list",
      description: "List invoices",
      visibility: :hidden,
      read_only?: true
    )
    |> Catalog.register!(DraftNote,
      id: "support.note.draft",
      description: "Draft note",
      visibility: :hidden,
      read_only?: true
    )
    |> Catalog.register!(MutatingAction,
      id: "admin.mutate",
      description: "Mutate",
      visibility: :hidden,
      read_only?: false
    )
  end
end
