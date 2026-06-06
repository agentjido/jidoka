defmodule JidokaExample.LuaToolsAgentTest do
  use ExUnit.Case, async: true

  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsDescribe
  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsExecute
  alias JidokaExample.LuaToolsAgent.Actions.LuaToolsQuery
  alias JidokaExample.LuaToolsAgent.Actions.SearchCustomers
  alias JidokaExample.LuaToolsAgent.Agent
  alias JidokaExample.LuaToolsAgent.LuaRuntime
  alias JidokaExample.LuaToolsAgent.Catalog
  alias JidokaExample.LuaToolsAgent.Controls.RequireLuaExecution

  test "hidden Lua tools are backed by a Jido action catalog" do
    assert %Jido.Action.Catalog{} = catalog = Catalog.catalog()
    assert [%Jido.Action.Catalog.Entry{} | _entries] = Catalog.entries()

    assert {:ok, entry} = Jido.Action.Catalog.fetch(catalog, "billing.invoice.list_unpaid")
    assert entry.module == JidokaExample.LuaToolsAgent.Actions.ListUnpaidInvoices
    assert entry.visibility == :hidden
    assert entry.read_only?
    assert Catalog.lua_path(entry) == ["billing", "invoice", "list_unpaid"]
  end

  @script """
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
        tool = "billing.invoice.list_unpaid",
        arguments = {
          customer_id = {from = "search", path = {"customers", 1, "id"}},
          limit = 5
        }
      },
      {
        id = "note",
        tool = "support.note.draft_followup",
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

  test "agent exposes only the three model-visible Lua layer operations" do
    assert ["lua_tools_query", "lua_tools_describe", "lua_tools_execute"] =
             Agent.spec().operations |> Enum.map(& &1.name)
  end

  test "query and describe return a compact selected hidden catalog" do
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
               tool["returns"] =~ ~s|{from = "search", path = {"customers"}}|
           end)

    assert query_result["notice"] =~ "Catalog metadata only"
    assert describe_result["notice"] =~ "Catalog metadata only"
    assert describe_result["next"] =~ "step tool values"
    assert describe_result["next"] =~ "Do not call hidden tools as Lua globals"

    assert {:ok, draft_result} =
             LuaToolsDescribe.run(%{"ids" => ["support.note.draft_followup"]}, %{})

    assert [%{"description" => description}] = draft_result["tools"]
    assert description =~ "customer_name"
    assert description =~ "total_due_cents"

    assert {:ok, portfolio_result} =
             LuaToolsDescribe.run(
               %{
                 "ids" => [
                   "crm.customer.search",
                   "billing.invoice.list_unpaid",
                   "support.note.draft_followup"
                 ]
               },
               %{}
             )

    assert portfolio_result["template"] =~ "return jidoka.workflow"
    assert portfolio_result["template"] =~ ~s|over = {from = "search", path = {"customers"}}|
    assert portfolio_result["template"] =~ ~s|invoice_count = {from = "invoice_count"|
  end

  test "customer search supports tier filters used by the Lua prompt" do
    assert {:ok, result} = SearchCustomers.run(%{"tier" => "enterprise", "limit" => 10}, %{})

    assert ["Ada Lovelace", "Grace Hopper"] =
             result["customers"] |> Enum.map(& &1["name"])
  end

  test "output control rejects final answers that did not execute Lua" do
    context = %{
      boundary: :output,
      agent_state: %Jidoka.Agent.State{operation_results: []}
    }

    assert {:block, :missing_lua_tools_execute} = RequireLuaExecution.call(context)
  end

  test "output control allows completed Lua execution results" do
    context = %{
      boundary: :output,
      agent_state: %Jidoka.Agent.State{
        operation_results: [
          %Jidoka.Effect.OperationResult{
            operation: "lua_tools_execute",
            output: %{"status" => "completed"}
          }
        ]
      }
    }

    assert :cont = RequireLuaExecution.call(context)
  end

  test "output control allows a repaired Lua execution after a failed attempt" do
    context = %{
      boundary: :output,
      agent_state: %Jidoka.Agent.State{
        operation_results: [
          %Jidoka.Effect.OperationResult{
            operation: "lua_tools_execute",
            output: %{"status" => "failed", "reason" => "missing return"}
          },
          %Jidoka.Effect.OperationResult{
            operation: "lua_tools_execute",
            output: %{"status" => "completed"}
          }
        ]
      }
    }

    assert :cont = RequireLuaExecution.call(context)
  end

  test "output control reports the most recent failed Lua execution" do
    context = %{
      boundary: :output,
      agent_state: %Jidoka.Agent.State{
        operation_results: [
          %Jidoka.Effect.OperationResult{
            operation: "lua_tools_execute",
            output: %{"status" => "failed", "reason" => "old error"}
          },
          %Jidoka.Effect.OperationResult{
            operation: "lua_tools_execute",
            output: %{"status" => "failed", "reason" => "new error"}
          }
        ]
      }
    }

    assert {:block, {:lua_execution_not_completed, "failed", "new error"}} =
             RequireLuaExecution.call(context)
  end

  test "execute runs a Lua-authored workflow over multiple hidden read-only actions" do
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

    assert %{"note" => note} = result["result"]["output"]
    assert note =~ "Ada Lovelace"
  end

  test "execute returns repair guidance when Lua does not return the workflow result" do
    script = """
    jidoka.workflow({
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

    assert {:ok, result} =
             LuaToolsExecute.run(
               %{"script" => script, "allowed_tools" => ["crm.customer.search"]},
               %{}
             )

    assert result["status"] == "failed"
    assert result["reason"] == "Lua script must return jidoka.workflow({...})."
    assert result["next"] =~ "call lua_tools_execute again"
    assert result["call_count"] == 1
  end

  test "execute returns repair guidance for setup and policy errors" do
    assert {:ok, result} =
             LuaToolsExecute.run(
               %{"script" => "return {}", "allowed_tools" => ["missing.tool"]},
               %{}
             )

    assert result["status"] == "failed"
    assert result["reason"] =~ "unknown_lua_tool"
    assert result["call_count"] == 0
    assert result["next"] =~ "call lua_tools_execute again"
  end

  test "execute preserves field-specific defaults for invalid numeric params" do
    script = """
    return jidoka.workflow({
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

    assert {:ok, result} =
             LuaToolsExecute.run(
               %{
                 "script" => script,
                 "allowed_tools" => ["crm.customer.search"],
                 "timeout" => "bad"
               },
               %{}
             )

    assert result["status"] == "completed"
    assert result["policy"]["timeout_ms"] == 1_500
  end

  test "jidoka.workflow executes a Lua-authored DAG with resolved step refs" do
    script = """
    local workflow = jidoka.workflow({
      id = "invoice_followup",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Northwind", limit = 1}
        },
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {
            customer_id = {from = "search", path = {"customers", 1, "id"}},
            limit = 5
          }
        },
        {
          id = "note",
          tool = "support.note.draft_followup",
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

    return workflow
    """

    assert {:ok, result} =
             LuaRuntime.execute(script,
               allowed_tools: [
                 "crm.customer.search",
                 "billing.invoice.list_unpaid",
                 "support.note.draft_followup"
               ],
               timeout: 3_000
             )

    assert result["status"] == "completed"
    assert result["call_count"] == 3
    assert result["result"]["workflow_id"] == "invoice_followup"
    assert result["result"]["output"]["note"] =~ "Ada Lovelace"
    assert result["result"]["steps"]["invoices"]["total_due_cents"] == 60_500
  end

  test "jidoka.workflow runs independent DAG roots in parallel through Runic" do
    test_pid = self()

    script = """
    local workflow = jidoka.workflow({
      id = "invoice_parallel_roots",
      steps = {
        {
          id = "ada_invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = "cus_ada", limit = 1}
        },
        {
          id = "grace_invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = "cus_grace", limit = 1}
        }
      },
      output = {
        ada = {from = "ada_invoices", path = {"total_due_cents"}},
        grace = {from = "grace_invoices", path = {"total_due_cents"}}
      }
    })

    return workflow
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
        assert_receive {:lua_hidden_action_started, "billing.invoice.list_unpaid", customer_id,
                        action_pid},
                       1_000

        {customer_id, action_pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["cus_ada", "cus_grace"]

    Enum.each(started, fn {_customer_id, action_pid} ->
      send(action_pid, :continue_lua_hidden_action)
    end)

    assert {:ok, result} = Task.await(task, 3_000)
    assert result["status"] == "completed"
    assert result["call_count"] == 2
    assert result["result"]["output"] == %{"ada" => 42_500, "grace" => 132_000}
  end

  test "jidoka.workflow maps tool calls, reduces results, and gates downstream steps" do
    test_pid = self()

    script = """
    return jidoka.workflow({
      id = "mapped_invoice_followup",
      steps = {
        {
          id = "invoices",
          map = {
            over = {
              {id = "cus_ada", name = "Ada Lovelace", company = "Northwind"},
              {id = "cus_grace", name = "Grace Hopper", company = "Contoso"}
            },
            as = "customer",
            tool = "billing.invoice.list_unpaid",
            arguments = {
              customer_id = {var = "customer", path = {"id"}},
              limit = 5
            },
            max_items = 2,
            max_concurrency = 2
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
      output = {
        total = {from = "total_due", path = {"value"}},
        gate = {from = "large_balance", path = {"passed"}},
        note = {from = "note", path = {"note"}}
      }
    })
    """

    task =
      Task.async(fn ->
        LuaRuntime.execute(script,
          allowed_tools: ["billing.invoice.list_unpaid", "support.note.draft_followup"],
          context: %{lua_test_pid: test_pid},
          max_parallel_calls: 2,
          timeout: 4_000
        )
      end)

    started =
      for _ <- 1..2 do
        assert_receive {:lua_hidden_action_started, "billing.invoice.list_unpaid", customer_id,
                        action_pid},
                       1_000

        {customer_id, action_pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["cus_ada", "cus_grace"]

    Enum.each(started, fn {_customer_id, action_pid} ->
      send(action_pid, :continue_lua_hidden_action)
    end)

    assert {:ok, result} = Task.await(task, 4_000)
    assert result["status"] == "completed"
    assert result["call_count"] == 3
    assert result["result"]["output"]["total"] == 192_500
    assert result["result"]["output"]["gate"] == true
    assert result["result"]["output"]["note"] =~ "Portfolio Team"
    assert result["result"]["steps"]["invoices"]["count"] == 2
    assert result["result"]["steps"]["invoices"]["truncated"] == false
  end

  test "jidoka.workflow gate can skip a downstream tool step" do
    script = """
    return jidoka.workflow({
      id = "skip_followup",
      steps = {
        {
          id = "large_balance",
          gate = {
            op = "gt",
            left = 10,
            right = 100
          }
        },
        {
          id = "note",
          tool = "support.note.draft_followup",
          when = {from = "large_balance", path = {"passed"}},
          arguments = {
            customer_name = "Portfolio Team",
            company = "ExampleCo",
            invoice_count = 1,
            total_due_cents = 1000
          }
        }
      },
      output = {
        gate = {from = "large_balance", path = {"passed"}},
        note = {from = "note"}
      }
    })
    """

    assert {:ok, result} =
             LuaRuntime.execute(script,
               allowed_tools: ["support.note.draft_followup"],
               timeout: 3_000
             )

    assert result["status"] == "completed"
    assert result["call_count"] == 0
    assert result["result"]["output"]["gate"] == false

    assert result["result"]["output"]["note"] == %{
             "reason" => "condition_false",
             "status" => "skipped"
           }
  end

  test "jidoka.workflow rejects ambiguous compound steps with top-level action fields" do
    script = """
    return jidoka.workflow({
      id = "ambiguous_map",
      steps = {
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          map = {
            over = {{id = "cus_ada"}},
            tool = "billing.invoice.list_unpaid",
            arguments = {customer_id = {var = "item", path = {"id"}}}
          }
        }
      },
      output = "invoices"
    })
    """

    assert {:error, result} =
             LuaRuntime.execute(script,
               allowed_tools: ["billing.invoice.list_unpaid"],
               timeout: 3_000
             )

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["reason"] =~ "ambiguous_lua_workflow_step"
    assert result["reason"] =~ "tool"
  end

  test "jidoka.workflow rejects multi-step dependency cycles before execution" do
    script = """
    return jidoka.workflow({
      id = "cyclic_workflow",
      steps = {
        {
          id = "first",
          tool = "billing.invoice.list_unpaid",
          after = {"second"},
          arguments = {customer_id = "cus_ada"}
        },
        {
          id = "second",
          tool = "billing.invoice.list_unpaid",
          after = {"first"},
          arguments = {customer_id = "cus_grace"}
        }
      },
      output = "second"
    })
    """

    assert {:error, result} =
             LuaRuntime.execute(script,
               allowed_tools: ["billing.invoice.list_unpaid"],
               timeout: 3_000
             )

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["reason"] =~ "cyclic_lua_workflow_dependency"
  end

  test "jidoka.workflow returns repairable validation errors for invalid refs" do
    script = """
    return jidoka.workflow({
      steps = {
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = {from = "missing_customer", path = {"id"}}}
        }
      },
      output = "invoices"
    })
    """

    assert {:error, result} =
             LuaRuntime.execute(script,
               allowed_tools: ["billing.invoice.list_unpaid"],
               timeout: 3_000
             )

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["reason"] =~ "missing_lua_workflow_dependencies"
    assert result["reason"] =~ "missing_customer"
  end

  test "jidoka.workflow returns repairable execution errors for ambiguous refs" do
    script = """
    return jidoka.workflow({
      id = "ambiguous_ref",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Northwind", limit = 1}
        },
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {
            customer_id = {
              from = "search",
              var = "customer",
              path = {"customers", 1, "id"}
            }
          }
        }
      },
      output = "invoices"
    })
    """

    assert {:error, result} =
             LuaRuntime.execute(script,
               allowed_tools: ["crm.customer.search", "billing.invoice.list_unpaid"],
               timeout: 3_000
             )

    assert result["status"] == "failed"
    assert result["call_count"] == 1
    assert result["reason"] =~ "ambiguous_lua_workflow_ref"
  end

  test "jidoka.workflow retries failed DAG steps within policy limits" do
    test_pid = self()

    script = """
    return jidoka.workflow({
      retries = 1,
      steps = {
        {
          id = "invoices",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = "cus_ada", limit = 5}
        }
      },
      output = "invoices"
    })
    """

    task =
      Task.async(fn ->
        LuaRuntime.execute(script,
          allowed_tools: ["billing.invoice.list_unpaid"],
          context: %{lua_retry_test_pid: test_pid},
          timeout: 3_000
        )
      end)

    assert_receive {:lua_retry_invoice_attempt, "cus_ada", action_pid}, 1_000
    send(action_pid, :fail_lua_invoice_attempt)

    assert_receive {:lua_retry_invoice_attempt, "cus_ada", action_pid}, 1_000
    send(action_pid, :fail_lua_invoice_attempt)

    assert_receive {:lua_retry_invoice_attempt, "cus_ada", action_pid}, 1_000
    send(action_pid, :continue_lua_invoice_attempt)

    assert {:ok, result} = Task.await(task, 4_000)
    assert result["status"] == "completed"
    assert result["call_count"] == 2
    assert [%{"status" => "error"}, %{"status" => "ok"}] = result["calls"]
    assert result["result"]["output"]["count"] == 2
  end

  test "execute returns Lua script failures as structured tool observations" do
    script = """
    return jidoka.workflow({
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Northwind", limit = 1}
        }
      },
      output = {from = "search", path = {"result", "customers"}}
    })
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
    assert result["reason"] =~ "missing_lua_workflow_path"
    assert result["reason"] =~ "result"
    assert result["call_count"] == 1
  end

  test "runtime does not expose hidden catalog functions directly" do
    script = """
    return crm.customer.search({name = "Northwind"})
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

    assert result["status"] == "failed"
    assert result["call_count"] == 0
    assert result["reason"] =~ "global 'crm'"
  end

  test "runtime rejects scripts that exceed the hidden call limit" do
    script = """
    return jidoka.workflow({
      steps = {
        {
          id = "ada",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = "cus_ada"}
        },
        {
          id = "grace",
          tool = "billing.invoice.list_unpaid",
          arguments = {customer_id = "cus_grace"}
        }
      },
      output = {ada = {from = "ada"}, grace = {from = "grace"}}
    })
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
