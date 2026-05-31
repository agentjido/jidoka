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

defmodule Jidoka.ImportToolSourcesTest do
  use ExUnit.Case, async: false

  alias Jidoka.ImportToolSourcesTest.Support.{AccountResource, FakeAshJidoTools}

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

  test "YAML imports support ash_resource, browser, and catalog tool sources" do
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
      catalogs:
        - name: support
          providers:
            - support
          max_results: 2
          metadata:
            owner: ops
    """

    assert {:ok, spec} =
             Jidoka.import(yaml,
               format: :yaml,
               ash_resources: %{"account_resource" => AccountResource}
             )

    operations = Map.new(spec.operations, &{&1.name, &1})

    assert %{
             "read_account" => %{metadata: %{"source" => "ash_resource", "risk" => "low"}},
             "search_web" => %{metadata: %{"source" => "browser", "browser" => "docs"}},
             "catalog_support" => %{metadata: %{"source" => "catalog", "owner" => "ops"}}
           } = operations

    refute Map.has_key?(operations, "update_account")

    assert [
             %{"source" => "ash_resource", "resource" => resource, "actions" => ["read_account"]},
             %{"source" => "browser", "name" => "docs", "mode" => "search"},
             %{"source" => "catalog", "name" => "support", "providers" => ["support"]}
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
end
