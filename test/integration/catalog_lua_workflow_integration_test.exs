defmodule Jidoka.CatalogLuaWorkflowIntegrationTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Catalog, as: ActionCatalog
  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule SearchDocsAction do
    @moduledoc false

    use Jidoka.Action,
      name: "catalog_integration_search_docs",
      description: "Searches integration documents.",
      schema:
        Zoi.object(%{
          query: Zoi.string(),
          limit: Zoi.integer() |> Zoi.default(3)
        })

    @impl true
    def run(params, context) do
      if pid = Jidoka.Context.get(context, :test_pid) do
        send(pid, {:hidden_catalog_action_called, params})
      end

      {:ok,
       %{
         "query" => Map.get(params, "query"),
         "count" => 1,
         "documents" => [
           %{
             "id" => "doc_catalog_lua",
             "title" => "Catalog-backed Lua workflows",
             "summary" => "Catalog operations can execute Lua-authored workflow plans."
           }
         ]
       }}
    end
  end

  defmodule TestCatalog do
    @moduledoc false

    def catalog do
      ActionCatalog.new!(id: "catalog-lua-integration", name: "Catalog Lua Integration")
      |> ActionCatalog.register!(SearchDocsAction,
        id: "docs.search",
        description: "Search internal docs.",
        visibility: :hidden,
        read_only?: true,
        metadata: %{
          "lua" => %{
            "returns" => "Returns documents and count.",
            "example" => ~s|{id = "search", tool = "docs.search", arguments = {query = "catalog", limit = 1}}|
          }
        }
      )
    end
  end

  defmodule AuditCatalogOperation do
    @moduledoc false

    use Jidoka.Control, name: "audit_catalog_operation"

    @impl true
    def call(operation) do
      send(operation.context.test_pid, {
        :catalog_operation_control,
        operation.kind,
        operation.source,
        operation.operation
      })

      :cont
    end
  end

  defmodule RequireCatalogExecute do
    @moduledoc false

    use Jidoka.Control, name: "require_catalog_execute"

    @impl true
    def call(%{boundary: :output, agent_state: %{operation_results: operation_results}})
        when is_list(operation_results) do
      if Enum.any?(operation_results, &completed_catalog_execute?/1) do
        :cont
      else
        {:block, :missing_catalog_execute}
      end
    end

    def call(%{boundary: :output}), do: {:block, :missing_operation_results}
    def call(_context), do: :cont

    defp completed_catalog_execute?(%{operation: "catalog_execute", output: %{"status" => "completed"}}),
      do: true

    defp completed_catalog_execute?(_result), do: false
  end

  defmodule CatalogAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :catalog_lua_workflow_integration_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the catalog-backed Lua workflow operations before answering."
    end

    tools do
      catalog TestCatalog
    end

    controls do
      max_turns 6
      operation AuditCatalogOperation, when: [kind: :catalog, name: :catalog_execute]
      output RequireCatalogExecute
    end
  end

  test "agent loop can query, describe, execute, and answer through a catalog-backed Lua workflow" do
    test_pid = self()

    llm = fn intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          prompt = Jidoka.Schema.get_key(intent.payload, :prompt)
          operations = Jidoka.Schema.get_key(prompt, :operations)

          assert Enum.map(operations, & &1.name) == [
                   "catalog_query",
                   "catalog_describe",
                   "catalog_execute"
                 ]

          {:ok, %{type: :operation, name: "catalog_query", arguments: %{"query" => "docs"}}}

        1 ->
          {:ok,
           %{
             type: :operation,
             name: "catalog_describe",
             arguments: %{"ids" => ["docs.search"]}
           }}

        2 ->
          {:ok,
           %{
             type: :operation,
             name: "catalog_execute",
             arguments: %{
               "allowed_tools" => ["docs.search"],
               "script" => """
               return jidoka.workflow({
                 id = "catalog_doc_lookup",
                 steps = {
                   {
                     id = "search",
                     tool = "docs.search",
                     arguments = {query = "catalog", limit = 1}
                   }
                 },
                 output = "search"
               })
               """
             }
           }}

        3 ->
          assert journal.results
                 |> Map.values()
                 |> Enum.any?(&match?(%Effect.Result{kind: :operation}, &1))

          {:ok, %{type: :final, content: "Catalog-backed Lua workflow completed."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Find docs about catalog Lua workflows.",
        context: %{test_pid: test_pid}
      )

    assert {:ok, %Turn.Result{content: "Catalog-backed Lua workflow completed."} = result} =
             CatalogAgent.run_turn(request,
               llm: llm,
               operation_context: %{test_pid: test_pid}
             )

    assert_receive {:catalog_operation_control, :catalog, "catalog", "catalog_execute"}
    assert_receive {:hidden_catalog_action_called, %{query: "catalog", limit: 1}}

    assert [
             %Effect.OperationResult{operation: "catalog_query", output: query_output},
             %Effect.OperationResult{operation: "catalog_describe", output: describe_output},
             %Effect.OperationResult{operation: "catalog_execute", output: execute_output}
           ] = result.agent_state.operation_results

    assert [%{"id" => "docs.search"}] = query_output["tools"]
    assert [%{"id" => "docs.search"}] = describe_output["tools"]
    assert execute_output["status"] == "completed"
    assert execute_output["call_count"] == 1
    assert execute_output["result"]["workflow_id"] == "catalog_doc_lookup"

    assert [
             %{
               "id" => "doc_catalog_lua",
               "title" => "Catalog-backed Lua workflows"
             }
           ] = execute_output["result"]["output"]["documents"]
  end
end
