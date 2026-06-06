defmodule Jidoka.ImportToolSourcesTest.Support.ReadAccountAction do
  use Jidoka.Action,
    name: "read_account",
    description: "Reads an account.",
    schema: Zoi.object(%{id: Zoi.string()})

  @impl true
  def run(params, _context) do
    {:ok, %{id: Map.get(params, "id") || Map.get(params, :id), status: "active"}}
  end
end

defmodule Jidoka.ImportToolSourcesTest.Support.UpdateAccountAction do
  use Jidoka.Action,
    name: "update_account",
    description: "Updates an account.",
    schema: Zoi.object(%{id: Zoi.string()})

  @impl true
  def run(params, _context) do
    {:ok, %{id: Map.get(params, "id") || Map.get(params, :id), status: "updated"}}
  end
end

defmodule Jidoka.ImportToolSourcesTest.Support.AccountResource do
  @moduledoc false
end

defmodule Jidoka.ImportToolSourcesTest.Support.FakeAshJidoTools do
  @moduledoc false

  alias Jidoka.ImportToolSourcesTest.Support.{
    AccountResource,
    ReadAccountAction,
    UpdateAccountAction
  }

  def actions(AccountResource), do: [ReadAccountAction, UpdateAccountAction]
  def actions(_resource), do: []
end

defmodule Jidoka.ImportToolSourcesTest.Support.AccountCatalog do
  @moduledoc false

  alias Jidoka.ImportToolSourcesTest.Support.ReadAccountAction

  def catalog do
    Jido.Action.Catalog.new!(id: "account-catalog", name: "Account Catalog")
    |> Jido.Action.Catalog.register!(ReadAccountAction,
      id: "account.read",
      description: "Read an account through the catalog.",
      visibility: :hidden,
      read_only?: true
    )
  end

  def templates do
    %{
      "read_account" =>
        ~s|return jidoka.workflow({steps = {{id = "read", tool = "account.read", arguments = {id = "acct_1"}}}, output = "read"})|
    }
  end
end

defmodule Jidoka.ImportToolSourcesTest do
  use ExUnit.Case, async: false

  alias Jidoka.ImportToolSourcesTest.Support.{AccountCatalog, AccountResource, FakeAshJidoTools}

  setup do
    original = Application.get_env(:jidoka, :ash_jido_tools)
    Application.put_env(:jidoka, :ash_jido_tools, FakeAshJidoTools)

    on_exit(fn ->
      if original do
        Application.put_env(:jidoka, :ash_jido_tools, original)
      else
        Application.delete_env(:jidoka, :ash_jido_tools)
      end
    end)
  end

  test "YAML imports support ash_resource, browser, MCP, and catalog tool sources" do
    yaml = """
    agent:
      id: import_sources_agent
      model:
        provider: test
        id: import-sources-model
      instructions: Use the imported operation sources.
    tools:
      ash_resources:
        - ref: account_resource
          actions:
            - read_account
          metadata:
            risk: low
      browsers:
        - name: docs
          mode: search
          allow:
            - docs.example.com
      mcp_tools:
        - endpoint: demo_mcp
          prefix: mcp_
          transport:
            type: stdio
            command: echo
          client_info:
            name: jidoka-import-test
          protocol_version: "2025-06-18"
          capabilities:
            tools: {}
          timeouts:
            request_ms: 777
          tools:
            - name: lookup_policy
              description: Looks up a policy.
              input_schema:
                type: object
      catalogs:
        - ref: account_catalog
    """

    assert {:ok, spec} =
             Jidoka.import(yaml,
               format: :yaml,
               ash_resources: %{"account_resource" => AccountResource},
               catalogs: %{"account_catalog" => AccountCatalog}
             )

    operations = Map.new(spec.operations, &{&1.name, &1})

    assert %{
             "read_account" => %{metadata: %{"source" => "ash_resource", "risk" => "low"}},
             "search_web" => %{metadata: %{"source" => "browser", "browser" => "docs"}},
             "mcp_lookup_policy" => %{metadata: %{"source" => "mcp", "endpoint" => "demo_mcp"}},
             "catalog_query" => %{metadata: %{"source" => "catalog", "prefix" => "catalog_"}},
             "catalog_describe" => %{metadata: %{"source" => "catalog", "operation" => "describe"}},
             "catalog_execute" => %{metadata: %{"source" => "catalog", "operation" => "execute"}}
           } = operations

    refute Map.has_key?(operations, "update_account")

    assert [
             %{"source" => "ash_resource", "resource" => resource, "actions" => ["read_account"]},
             %{"source" => "browser", "name" => "docs", "mode" => "search"},
             %{
               "source" => "mcp",
               "endpoint" => "demo_mcp",
               "protocol_version" => "2025-06-18",
               "client_info" => %{"name" => "jidoka-import-test"},
               "timeouts" => %{"request_ms" => 777}
             },
             %{
               "source" => "catalog",
               "catalog_id" => "account-catalog",
               "prefix" => "catalog_",
               "tools" => ["account.read"]
             }
           ] = spec.metadata["tool_sources"]

    assert resource == inspect(AccountResource)
  end

  test "imports reject unknown ash resource refs without atom creation" do
    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unknown_registry_ref, :ash_resources, "Missing.Resource"}}
            }} =
             Jidoka.Import.load(%{
               agent: %{id: "safe_ash_import", model: %{provider: :test, id: "model"}},
               tools: %{ash_resources: [%{ref: "Missing.Resource"}]}
             })
  end

  test "imports reject unknown catalog refs without atom creation" do
    assert {:error,
            %Jidoka.Error.ValidationError{
              details: %{reason: {:unknown_registry_ref, :catalogs, "Missing.Catalog"}}
            }} =
             Jidoka.Import.load(%{
               agent: %{id: "safe_catalog_import", model: %{provider: :test, id: "model"}},
               tools: %{catalogs: [%{ref: "Missing.Catalog"}]}
             })
  end
end
