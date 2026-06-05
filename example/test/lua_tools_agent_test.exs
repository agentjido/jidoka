defmodule JidokaExample.LuaToolsAgentTest do
  use ExUnit.Case, async: true

  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe
  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute
  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsQuery
  alias JidokaExample.LuaToolsAgent.Agent
  alias JidokaExample.LuaToolsAgent.LuaRuntime
  alias JidokaExample.LuaToolsAgent.Surface

  test "hidden Lua tools are backed by a Jido action catalog" do
    assert %Jido.Action.Catalog{} = catalog = Surface.catalog()
    assert [%Jido.Action.Catalog.Entry{} | _entries] = Surface.entries()

    assert {:ok, entry} = Jido.Action.Catalog.fetch(catalog, "billing.invoice.list_unpaid")
    assert entry.module == JidokaExample.LuaToolsAgent.Actions.ListUnpaidInvoices
    assert entry.visibility == :hidden
    assert entry.read_only?
    assert Surface.lua_path(entry) == ["billing", "invoice", "list_unpaid"]
  end

  @script """
  local customers = crm.customer.search({query = "Northwind", limit = 2})
  local output = {}
  for _, customer in ipairs(customers.customers) do
    local invoices = billing.invoice.list_unpaid({customer_id = customer.id, limit = 5})
    local note = support.note.draft_followup({customer_name = customer.name, company = customer.company, invoice_count = invoices.count, total_due_cents = invoices.total_due_cents})
    table.insert(output, {customer = customer, invoices = invoices, note = note})
  end
  return {items = output}
  """

  test "agent exposes only the three model-visible Lua layer operations" do
    assert ["lua_tools_query", "lua_tools_describe", "lua_tools_execute"] =
             Agent.spec().operations |> Enum.map(& &1.name)
  end

  test "query and describe return a compact selected hidden surface" do
    assert {:ok, query_result} = LuaToolsQuery.run(%{"query" => "unpaid invoice"}, %{})
    ids = Enum.map(query_result["tools"], & &1["id"])

    assert "billing.invoice.list_unpaid" in ids

    assert {:ok, describe_result} =
             LuaToolsDescribe.run(
               %{
                 "ids" => ["crm.customer.search", "billing.invoice.list_unpaid"]
               },
               %{}
             )

    assert [
             %{"lua_path" => "crm.customer.search"},
             %{"lua_path" => "billing.invoice.list_unpaid"}
           ] =
             describe_result["tools"]

    assert Enum.any?(describe_result["tools"], fn tool ->
             tool["lua_path"] == "crm.customer.search" and
               tool["returns"] =~ "search.customers"
           end)

    assert describe_result["next"] =~ "not wrapped in a result field"

    assert {:ok, draft_result} =
             LuaToolsDescribe.run(%{"ids" => ["support.note.draft_followup"]}, %{})

    assert [%{"description" => description}] = draft_result["tools"]
    assert description =~ "customer_name"
    assert description =~ "total_due_cents"
  end

  test "execute runs a Lua script over multiple hidden read-only actions" do
    assert {:ok, result} =
             LuaToolsExecute.run(
               %{
                 "script" => @script,
                 "allowed_tools" => [
                   "crm.customer.search",
                   "billing.invoice.list_unpaid",
                   "support.note.draft_followup"
                 ]
               },
               %{}
             )

    assert result["status"] == "completed"
    assert result["call_count"] == 3

    assert Enum.map(result["calls"], & &1["tool"]) == [
             "crm.customer.search",
             "billing.invoice.list_unpaid",
             "support.note.draft_followup"
           ]

    assert [%{"note" => %{"note" => note}}] = result["result"]["items"]
    assert note =~ "Ada Lovelace"
  end

  test "jidoka.parallel maps hidden Lua tool calls into a Runic workflow" do
    test_pid = self()

    script = """
    local results = jidoka.parallel({
      {tool = "billing.invoice.list_unpaid", arguments = {customer_id = "cus_ada", limit = 1}},
      {tool = "billing.invoice.list_unpaid", arguments = {customer_id = "cus_grace", limit = 1}}
    })

    return {
      customers = {results[1].customer_id, results[2].customer_id},
      totals = {results[1].total_due_cents, results[2].total_due_cents}
    }
    """

    task =
      Task.async(fn ->
        LuaRuntime.execute(script,
          allowed_tools: ["billing.invoice.list_unpaid"],
          context: %{lua_test_pid: test_pid},
          max_parallel_calls: 2,
          timeout: 3_000
        )
      end)

    started =
      for _ <- 1..2 do
        assert_receive {:lua_hidden_action_started, "billing.invoice.list_unpaid", customer_id, action_pid},
                       1_000

        {customer_id, action_pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["cus_ada", "cus_grace"]
    Enum.each(started, fn {_customer_id, action_pid} -> send(action_pid, :continue_lua_hidden_action) end)

    assert {:ok, result} = Task.await(task, 3_000)
    assert result["status"] == "completed"
    assert result["call_count"] == 2
    assert result["policy"]["max_parallel_calls"] == 2
    assert result["result"]["customers"] == ["cus_ada", "cus_grace"]
    assert result["result"]["totals"] == [42_500, 132_000]
  end

  test "execute returns Lua script failures as structured tool observations" do
    script = """
    local search = crm.customer.search({query = "Northwind", limit = 1})
    return search.result.customers
    """

    assert {:ok, result} =
             LuaToolsExecute.run(
               %{
                 "script" => script,
                 "allowed_tools" => ["crm.customer.search"]
               },
               %{}
             )

    assert result["status"] == "failed"
    assert result["reason"] =~ "attempt to index a nil value"
    assert result["reason"] =~ "field 'result'"
    assert result["call_count"] == 1
  end

  test "execute tolerates common Lua shorthand argument shapes" do
    script = """
    local search = crm.customer.search({name = "Northwind"})
    local results = {}

    for _, customer in pairs(search.customers) do
      local invoices = billing.invoice.list_unpaid(customer.id)
      local note = support.note.draft_followup({
        customer_name = customer.name,
        company = customer.company,
        invoice_count = invoices.count,
        total_due_cents = invoices.total_due_cents
      })

      table.insert(results, {customer = customer, invoices = invoices, note = note})
    end

    return results
    """

    assert {:ok, result} =
             LuaToolsExecute.run(
               %{
                 "script" => script,
                 "allowed_tools" => [
                   "crm.customer.search",
                   "billing.invoice.list_unpaid",
                   "support.note.draft_followup"
                 ]
               },
               %{}
             )

    assert result["status"] == "completed"
    assert result["call_count"] == 3
    assert [%{"note" => %{"note" => note}}] = result["result"]
    assert note =~ "Ada Lovelace"
  end

  test "runtime rejects scripts that exceed the hidden call limit" do
    script = """
    crm.customer.search({query = "Northwind"})
    billing.invoice.list_unpaid({customer_id = "cus_ada"})
    return {ok = true}
    """

    assert {:error, result} = LuaRuntime.execute(script, max_calls: 1)
    assert result["status"] == "failed"
    assert result["call_count"] == 1
    assert result["reason"] =~ "max_lua_tool_calls_exceeded"
  end

  test "runtime keeps Lua 1.0 sandbox defaults enabled" do
    assert {:error, result} = LuaRuntime.execute(~s|return os.getenv("HOME")|)

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["policy"]["sandbox"] == "lua_default"
    assert result["reason"] =~ "sandboxed"
  end

  test "runtime bounds recursive Lua scripts with max call depth" do
    script = """
    local function loop(n)
      return loop(n + 1)
    end

    return loop(1)
    """

    assert {:error, result} = LuaRuntime.execute(script, max_call_depth: 4)

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["policy"]["max_call_depth"] == 4
    assert result["reason"] =~ "stack overflow"
  end

  test "runtime rejects unknown allowed tools" do
    assert {:error, {:unknown_lua_tool, "admin.secret.dump"}} =
             LuaRuntime.execute("return {}", allowed_tools: ["admin.secret.dump"])
  end
end
