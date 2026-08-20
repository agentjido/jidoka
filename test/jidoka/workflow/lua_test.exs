defmodule Jidoka.Workflow.LuaTest do
  use ExUnit.Case, async: false

  alias Jido.Action.Catalog
  alias Jidoka.Adapter.Runic.LuaPlan
  alias Jidoka.Workflow.Lua
  alias Jidoka.Workflow.Lua.CallTrace
  alias Jidoka.Workflow.Lua.Plan.Ref
  alias Jidoka.Workflow.Lua.Plan.Spec
  alias Jidoka.Workflow.Lua.Plan.Spec.Helpers
  alias Jidoka.Workflow.Lua.Policy

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

  defmodule ReadActionContext do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_read_action_context",
      description: "Reads caller data from the Jido action context.",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, context) do
      {:ok,
       %{
         actor: Map.get(context, :actor),
         access_actor: context[:actor],
         helper_actor: Jidoka.Context.get(context, :actor)
       }}
    end
  end

  defmodule AlwaysFails do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_lua_always_fails",
      description: "Returns a deterministic action error.",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context), do: {:error, :deterministic_failure}
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

  test "Lua refs resolve atom, string, variable, list, and dotted paths" do
    atom_values = %{
      customer_id: "customer",
      id: "id",
      name: "name",
      company: "company",
      count: 1,
      total_due_cents: 2,
      customers: [],
      invoices: [],
      note: "note",
      output: "output",
      steps: "steps"
    }

    state = %{
      steps: %{
        "atom_values" => atom_values,
        "nested" => %{"items" => [%{"value" => 1}, %{"value" => 2}]}
      }
    }

    for {key, expected} <- atom_values do
      assert {:ok, ^expected} = Ref.resolve(%{from: :atom_values, path: Atom.to_string(key)}, state)
    end

    assert {:ok, 2} = Ref.resolve(%{"from" => "nested", "path" => ["items", "2", "value"]}, state)
    assert {:ok, 1} = Ref.resolve(%{var: :item, path: [:value]}, state, %{"item" => %{"value" => 1}})

    assert {:ok, %{"value" => 1}} =
             Ref.resolve(%{var: "item", path: nil}, state, %{"item" => %{"value" => 1}})

    assert {:ok, %{resolved: [1, 2]}} =
             Ref.resolve(
               %{resolved: [%{from: "nested", path: ["items", 1, "value"]}, 2]},
               state
             )

    assert Ref.collect(%{
             first: %{from: "one"},
             nested: [%{from: :two}, %{from: "one"}],
             plain: 1
           }) == ["one", "two"]
  end

  test "Lua refs return precise errors for missing and invalid paths" do
    state = %{steps: %{"one" => %{"items" => [1]}}}

    cases = [
      {%{from: "one", var: "item"}, %{}, {:ambiguous_lua_workflow_ref, %{from: "one", var: "item"}}},
      {%{from: "missing"}, %{}, {:missing_lua_workflow_ref, "missing"}},
      {%{var: "missing"}, %{}, {:missing_lua_workflow_var, "missing"}},
      {%{from: "one", path: "missing"}, %{}, {:missing_lua_workflow_path, "one", "missing"}},
      {%{from: "one", path: ["items", "bad"]}, %{}, {:missing_lua_workflow_path, "one", "bad"}},
      {%{from: "one", path: ["items", 0]}, %{}, {:missing_lua_workflow_path, "one", 0}},
      {%{from: "one", path: ["items", 2]}, %{}, :error},
      {%{from: "one", path: ["items", 1, "bad"]}, %{}, {:invalid_lua_workflow_path_target, "one", "bad", 1}}
    ]

    Enum.each(cases, fn {ref, vars, expected} ->
      assert {:error, ^expected} = Ref.resolve(ref, state, vars)
    end)

    assert {:error, {:missing_lua_workflow_ref, "missing"}} =
             Ref.resolve([%{from: "missing"}, 1], state)

    assert {:error, {:missing_lua_workflow_ref, "missing"}} =
             Ref.resolve(%{nested: %{from: "missing"}}, state)
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

  test "Lua workflow actions receive the projected Jido action context" do
    script = """
    return jidoka.workflow({
      id = "context_projection",
      steps = {
        {id = "context", tool = "context.read", arguments = {}}
      },
      output = "context"
    })
    """

    assert {:ok, result} = Lua.execute(script, catalog: catalog(), context: %{actor: "actor-1"})

    assert result["result"]["output"] == %{
             "actor" => "actor-1",
             "access_actor" => "actor-1",
             "helper_actor" => "actor-1"
           }
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

  test "supports all reduce modes and gate comparisons" do
    script = """
    return jidoka.workflow({
      id = "reduce_and_gate_modes",
      steps = {
        {id = "collect", reduce = {over = {1, 2, 3}, mode = "collect"}},
        {id = "count", reduce = {over = {1, 2, 3}, mode = "count"}},
        {id = "first", reduce = {over = {1, 2, 3}, mode = "first"}},
        {id = "exists", gate = {op = "exists", left = 1}},
        {id = "empty", gate = {op = "empty", left = ""}},
        {id = "not_empty", gate = {op = "not_empty", left = {1}}},
        {id = "eq", gate = {op = "eq", left = 1, right = 1}},
        {id = "neq", gate = {op = "neq", left = 1, right = 2}},
        {id = "gte", gate = {op = "gte", left = 2, right = 2}},
        {id = "lt", gate = {op = "lt", left = 1, right = 2}},
        {id = "lte", gate = {op = "lte", left = 2, right = 2}},
        {id = "contains_text", gate = {op = "contains", left = "jidoka", right = "ido"}},
        {id = "contains_list", gate = {op = "contains", left = {1, 2}, right = 2}}
      },
      output = {
        collect = {from = "collect"},
        count = {from = "count"},
        first = {from = "first"},
        exists = {from = "exists", path = {"passed"}},
        empty = {from = "empty", path = {"passed"}},
        not_empty = {from = "not_empty", path = {"passed"}},
        eq = {from = "eq", path = {"passed"}},
        neq = {from = "neq", path = {"passed"}},
        gte = {from = "gte", path = {"passed"}},
        lt = {from = "lt", path = {"passed"}},
        lte = {from = "lte", path = {"passed"}},
        contains_text = {from = "contains_text", path = {"passed"}},
        contains_list = {from = "contains_list", path = {"passed"}}
      }
    })
    """

    assert {:ok, result} = Lua.execute(script, catalog: catalog())
    output = result["result"]["output"]
    assert output["collect"] == %{"mode" => "collect", "items" => [1, 2, 3], "count" => 3}
    assert output["count"] == %{"mode" => "count", "value" => 3, "count" => 3}
    assert output["first"] == %{"mode" => "first", "value" => 1, "count" => 3}

    for key <- ~w(exists empty not_empty eq neq gte lt lte contains_text contains_list) do
      assert output[key]
    end
  end

  test "reports invalid resolved collections, sums, and map arguments" do
    scripts = [
      """
      return jidoka.workflow({
        steps = {{id = "bad_reduce", reduce = {over = "not-a-list", mode = "count"}}},
        output = "bad_reduce"
      })
      """,
      """
      return jidoka.workflow({
        steps = {{id = "bad_sum", reduce = {over = {1, "bad"}, mode = "sum"}}},
        output = "bad_sum"
      })
      """,
      """
      return jidoka.workflow({
        steps = {{
          id = "bad_map",
          map = {over = {{id = 1}}, tool = "billing.invoice.list", arguments = "bad"}
        }},
        output = "bad_map"
      })
      """
    ]

    Enum.each(scripts, fn script ->
      assert {:error, result} = Lua.execute(script, catalog: catalog())
      assert result["status"] == "failed"
    end)
  end

  test "the Runic plan rejects invalid states, steps, and gate operations" do
    assert {:ok, policy} = Policy.build("return {}", catalog: catalog())
    assert {:ok, trace} = CallTrace.start_link()
    context = Jidoka.Context.from_data!(%{})

    assert {:error, {:invalid_lua_workflow, :invalid}} =
             LuaPlan.run(:invalid, trace, policy, context)

    invalid_state = LuaPlan.run_step(:invalid, %{id: "ignored"}, trace, policy, context)
    assert invalid_state.error == {:invalid_lua_workflow_state, :invalid}

    unsupported =
      LuaPlan.run_step(
        %{steps: %{}, error: nil},
        %{id: "unsupported", kind: :unsupported, condition: nil},
        trace,
        policy,
        context
      )

    assert unsupported.error ==
             {:lua_workflow_step_failed, "unsupported",
              {:unsupported_lua_workflow_step, %{id: "unsupported", kind: :unsupported, condition: nil}}}

    invalid_gate =
      LuaPlan.run_step(
        %{steps: %{}, error: nil},
        %{
          id: "gate",
          kind: :gate,
          condition: nil,
          gate: %{op: "invalid", left: 1, right: 2}
        },
        trace,
        policy,
        context
      )

    assert invalid_gate.error ==
             {:lua_workflow_step_failed, "gate", {:invalid_lua_workflow_gate, "invalid", 1, 2}}
  end

  test "Lua plan validation reports each malformed public field" do
    assert {:ok, policy} = Policy.build("return {}", catalog: catalog())
    assert Spec.schema()

    cases = [
      {:bad, {:invalid_lua_workflow, :bad}},
      {%{}, {:invalid_lua_workflow_steps, nil}},
      {%{"steps" => [:bad]}, {:invalid_lua_workflow_step, :bad}},
      {%{"steps" => [%{"id" => "one", "map" => %{}, "tool" => "crm.customer.search"}]},
       {:ambiguous_lua_workflow_step, "map", ["tool"]}},
      {%{"steps" => [%{"id" => "one", "map" => :bad}]}, {:invalid_lua_workflow_map_step, :bad}},
      {%{"steps" => [%{"id" => "one", "reduce" => :bad}]}, {:invalid_lua_workflow_reduce_step, :bad}},
      {%{"steps" => [%{"id" => "one", "gate" => :bad}]}, {:invalid_lua_workflow_gate_step, :bad}},
      {%{"steps" => [%{"id" => nil, "tool" => "crm.customer.search"}]}, {:invalid_lua_workflow_step_id, nil}},
      {%{"steps" => [%{"id" => "one", "tool" => nil}]}, {:invalid_lua_workflow_step_tool, nil}},
      {%{"steps" => [%{"id" => "one", "tool" => "not.allowed"}]}, {:lua_tool_not_allowed, "not.allowed"}},
      {%{"steps" => [%{"id" => "one", "tool" => "crm.customer.search", "arguments" => :bad}]},
       {:invalid_lua_workflow_step_arguments, :bad}},
      {%{"steps" => [%{"id" => "one", "map" => %{"tool" => "crm.customer.search"}}]},
       {:missing_lua_workflow_field, "over"}},
      {%{"steps" => [%{"id" => "one", "map" => %{"over" => [], "as" => nil, "tool" => "crm.customer.search"}}]},
       {:invalid_lua_workflow_map_as, nil}},
      {%{"steps" => [%{"id" => "one", "map" => %{"over" => [], "tool" => nil}}]},
       {:invalid_lua_workflow_map_tool, nil}},
      {%{"steps" => [%{"id" => "one", "map" => %{"over" => [], "tool" => "not.allowed"}}]},
       {:lua_tool_not_allowed, "not.allowed"}},
      {%{"steps" => [%{"id" => "one", "tool" => "crm.customer.search"}], "output" => %{"from" => "missing"}},
       {:missing_lua_workflow_output_refs, ["missing"]}}
    ]

    for {raw, reason} <- cases do
      assert {:error, ^reason} = Spec.new(raw, policy)
    end

    assert {:ok, atom_fields} =
             Spec.new(
               %{
                 steps: [
                   %{id: :one, tool: [:crm, :customer, :search], arguments: nil},
                   %{
                     id: :two,
                     map: %{over: [], as: :row, tool: [:billing, :invoice, :list], arguments: nil},
                     after: :one
                   }
                 ]
               },
               policy
             )

    assert atom_fields.output == %{"from" => "two"}
    assert Enum.map(atom_fields.steps, & &1.id) == ["one", "two"]
    assert Enum.at(atom_fields.steps, 1).after == ["one"]
  end

  test "Lua policy validates all catalog and bounded option inputs" do
    assert Policy.schema()
    entries = Catalog.list(catalog())

    assert {:ok, configured} =
             Policy.build("return {}",
               entries: entries,
               require_read_only?: false,
               allowed_tools: :"admin.mutate",
               timeout: :bad,
               max_calls: :bad,
               max_parallel_calls: :bad,
               max_call_depth: :bad,
               max_script_bytes: :bad
             )

    assert configured.allowed_tools == ["admin.mutate"]
    assert configured.require_read_only? == false

    assert {:ok, defaults} = Policy.build("return {}", entries: entries, allowed_tools: [])
    assert "crm.customer.search" in defaults.allowed_tools

    assert {:error, {:invalid_lua_workflow_entries, [:bad]}} =
             Policy.build("return {}", entries: [:bad])

    assert {:error, {:invalid_lua_workflow_catalog, :bad}} =
             Policy.build("return {}", catalog: :bad)

    assert {:error, :empty_lua_script} = Policy.build("  ", entries: entries)

    assert {:error, {:lua_script_too_large, 257, 256}} =
             Policy.build(String.duplicate("x", 257), entries: entries, max_script_bytes: 256)

    assert {:error, {:unknown_lua_tool, "unknown"}} =
             Policy.build("return {}", entries: entries, allowed_tools: "unknown")
  end

  test "action retry failures are traced for every bounded attempt" do
    script = """
    return jidoka.workflow({
      steps = {{id = "fail", tool = "test.always_fails", arguments = {}, retries = 1}},
      output = "fail"
    })
    """

    assert {:error, result} = Lua.execute(script, catalog: catalog())
    assert result["status"] == "failed"
    assert result["call_count"] == 2
    assert Enum.all?(result["calls"], &(&1["status"] == "error"))
  end

  test "rejects mutating tools by default" do
    assert {:error, {:lua_tool_not_read_only, "admin.mutate"}} =
             Lua.execute("return {}", catalog: catalog(), allowed_tools: ["admin.mutate"])
  end

  test "stops recursive scripts at the configured call depth" do
    script = """
    local function loop(n)
      return loop(n + 1)
    end

    return loop(1)
    """

    assert {:error, result} = Lua.execute(script, catalog: catalog(), max_call_depth: 4)
    assert result["policy"]["max_call_depth"] == 4
    assert result["reason"] =~ "stack overflow"
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
    |> Catalog.register!(ReadActionContext,
      id: "context.read",
      description: "Read action context",
      visibility: :hidden,
      read_only?: true
    )
    |> Catalog.register!(AlwaysFails,
      id: "test.always_fails",
      description: "Always fails",
      visibility: :hidden,
      read_only?: true
    )
  end
end
