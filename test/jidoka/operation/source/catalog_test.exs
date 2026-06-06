defmodule Jidoka.Operation.Source.CatalogTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Catalog, as: ActionCatalog
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog, as: CatalogSource
  alias Jidoka.Operation.Source.Catalog.Normalize

  defmodule SearchCustomers do
    @moduledoc false

    use Jidoka.Action,
      name: "catalog_source_search_customers",
      description: "Searches catalog source test customers.",
      schema:
        Zoi.object(%{
          query: Zoi.string() |> Zoi.default(""),
          limit: Zoi.integer() |> Zoi.default(5)
        })

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

  defmodule MutatingAction do
    @moduledoc false

    use Jidoka.Action,
      name: "catalog_source_mutating_action",
      description: "Mutates catalog source test state.",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context), do: {:ok, %{"mutated" => true}}
  end

  defmodule TestCatalog do
    @moduledoc false

    def catalog do
      ActionCatalog.new!(id: "catalog-source-test", name: "Catalog Source Test")
      |> ActionCatalog.register!(SearchCustomers,
        id: "crm.customer.search",
        description: "Search customers",
        visibility: :hidden,
        read_only?: true,
        metadata: %{
          "lua" => %{
            "returns" => "Returns customers and count.",
            "example" => ~s|{id = "search", tool = "crm.customer.search", arguments = {query = "Ada", limit = 1}}|
          }
        }
      )
      |> ActionCatalog.register!(MutatingAction,
        id: "admin.customer.delete",
        description: "Delete customers",
        visibility: :hidden,
        read_only?: false
      )
    end

    def templates do
      %{
        customer_search: """
        return jidoka.workflow({
          steps = {
            {id = "search", tool = "crm.customer.search", arguments = {query = "Ada", limit = 1}}
          },
          output = "search"
        })
        """
      }
    end
  end

  defmodule InvalidCatalog do
    @moduledoc false
  end

  defmodule BadReturnCatalog do
    @moduledoc false

    def catalog, do: :not_a_catalog
  end

  defmodule BadTemplatesCatalog do
    @moduledoc false

    def catalog, do: ActionCatalog.new!(id: "bad-templates", name: "Bad Templates")
    def templates, do: [:not, :a, :map]
  end

  test "publishes generated query, describe, and execute operations" do
    source = CatalogSource.new!(catalog: TestCatalog)

    assert {:ok, operations} = Source.operations(source)
    assert Enum.map(operations, & &1.name) == ["catalog_query", "catalog_describe", "catalog_execute"]

    assert Enum.all?(operations, &(&1.metadata["source"] == "catalog"))
    assert Enum.all?(operations, &(&1.metadata["kind"] == "catalog"))
    assert Enum.all?(operations, &(&1.metadata["prefix"] == "catalog_"))

    execute = Enum.find(operations, &(&1.name == "catalog_execute"))
    assert execute.metadata["parameters_schema"]["required"] == ["script", "allowed_tools"]
    assert execute.metadata["max_parallel_calls"] == 8
  end

  test "normalizes a custom prefix" do
    source = CatalogSource.new!(catalog: TestCatalog, prefix: :crm)

    assert {:ok, operations} = Source.operations(source)
    assert Enum.map(operations, & &1.name) == ["crm_query", "crm_describe", "crm_execute"]
  end

  test "catalog normalizers keep operation source inputs bounded and predictable" do
    assert {:ok, TestCatalog} = Normalize.catalog_module(TestCatalog)

    assert {:error, {:invalid_catalog_module, InvalidCatalog, :missing_catalog_callback}} =
             Normalize.catalog_module(InvalidCatalog)

    assert {:error, {:invalid_catalog_return, BadReturnCatalog, :not_a_catalog}} =
             Normalize.catalog_value(BadReturnCatalog)

    assert {:error, {:invalid_catalog_templates, BadTemplatesCatalog, [:not, :a, :map]}} =
             Normalize.templates(BadTemplatesCatalog)

    assert {:ok, "catalog_"} = Normalize.prefix(nil)
    assert {:ok, "crm_"} = Normalize.prefix(:crm)
    assert {:ok, "crm_"} = Normalize.prefix("crm_")
    assert {:error, {:invalid_catalog_prefix, "Bad Prefix"}} = Normalize.prefix("Bad Prefix")

    assert {:ok, 12} = Normalize.positive_integer("12", :max_calls)

    assert {:error, {:invalid_catalog_positive_integer, :max_calls, "0"}} =
             Normalize.positive_integer("0", :max_calls)

    assert {:ok, false} = Normalize.boolean(false, :require_read_only?)

    assert {:error, {:invalid_catalog_boolean, :require_read_only?, "false"}} =
             Normalize.boolean("false", :require_read_only?)

    assert {:ok, :structured} = Normalize.result(:structured)
    assert {:error, {:invalid_catalog_result, :output}} = Normalize.result(:output)

    assert {:ok, :pure} = Normalize.idempotency(:pure)
    assert {:error, {:invalid_catalog_idempotency, "pure"}} = Normalize.idempotency("pure")

    assert {:ok, %{"kind" => "demo"}} = Normalize.metadata(%{"kind" => "demo"})
    assert {:error, {:invalid_catalog_metadata, []}} = Normalize.metadata([])

    assert Normalize.context(tenant: "northwind") == %{tenant: "northwind"}
    assert Normalize.context(:invalid) == %{}
    assert Normalize.get(%{"limit" => 2}, :limit, 5) == 2
    assert Normalize.positive_integer_or_default("bad", 8) == 8
    assert Normalize.clamp(99, 1, 10) == 10
    assert Normalize.stringify_keys(%{mode: :safe}) == %{"mode" => :safe}
    assert Normalize.format_reason(:bad) == ":bad"
    assert Normalize.reject_nil_values(%{a: 1, b: nil}) == %{a: 1}
  end

  test "queries and describes catalog metadata without executing hidden actions" do
    source = CatalogSource.new!(catalog: TestCatalog)
    {:ok, %{capability: capability}} = Source.compile(source)
    ctx = Jidoka.Context.from_data!(%{})

    assert {:ok, query_result} =
             capability.(
               operation_intent("catalog_query", %{"query" => "customer"}),
               Effect.Journal.new!(),
               ctx
             )

    assert query_result["count"] == 1
    assert [%{"id" => "crm.customer.search", "read_only" => true}] = query_result["tools"]
    assert query_result["next"] =~ "catalog_describe"

    assert {:ok, describe_result} =
             capability.(
               operation_intent("catalog_describe", %{"ids" => ["crm.customer.search"]}),
               Effect.Journal.new!(),
               ctx
             )

    assert describe_result["allowed_tools"] == ["crm.customer.search"]
    assert [%{"id" => "crm.customer.search", "example" => example}] = describe_result["tools"]
    assert example =~ "crm.customer.search"
    assert describe_result["templates"]["customer_search"] =~ "jidoka.workflow"
    assert describe_result["next"] =~ "catalog_execute"
  end

  test "executes a Lua workflow over selected read-only catalog actions" do
    source = CatalogSource.new!(catalog: TestCatalog)
    {:ok, %{capability: capability}} = Source.compile(source)
    ctx = Jidoka.Context.from_data!(%{})

    script = """
    return jidoka.workflow({
      id = "catalog_source_customer_search",
      steps = {
        {
          id = "search",
          tool = "crm.customer.search",
          arguments = {query = "Ada", limit = 1}
        }
      },
      output = "search"
    })
    """

    assert {:ok, result} =
             capability.(
               operation_intent("catalog_execute", %{
                 "script" => script,
                 "allowed_tools" => ["crm.customer.search"]
               }),
               Effect.Journal.new!(),
               ctx
             )

    assert result["status"] == "completed"
    assert result["call_count"] == 1
    assert result["result"]["workflow_id"] == "catalog_source_customer_search"
    assert [%{"tool" => "crm.customer.search", "status" => "ok"}] = result["calls"]
    assert [%{"name" => "Ada Lovelace"}] = result["result"]["output"]["customers"]
  end

  test "returns repair guidance for invalid Lua workflow scripts" do
    source = CatalogSource.new!(catalog: TestCatalog)
    {:ok, %{capability: capability}} = Source.compile(source)
    ctx = Jidoka.Context.from_data!(%{})

    assert {:ok, result} =
             capability.(
               operation_intent("catalog_execute", %{
                 "script" => "return {}",
                 "allowed_tools" => ["crm.customer.search"]
               }),
               Effect.Journal.new!(),
               ctx
             )

    assert result["status"] == "failed"
    assert result["next"] =~ "catalog_execute again"
  end

  test "validates catalog source configuration" do
    assert {:error, {:invalid_catalog_module, InvalidCatalog, :missing_catalog_callback}} =
             CatalogSource.new(catalog: InvalidCatalog)

    assert {:error, {:invalid_catalog_prefix, "Bad Prefix"}} =
             CatalogSource.new(catalog: TestCatalog, prefix: "Bad Prefix")
  end

  defp operation_intent(name, arguments) do
    Effect.Intent.new(:operation, %{name: name, arguments: arguments})
  end
end
