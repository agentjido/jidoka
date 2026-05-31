defmodule Jidoka.OperationSourceTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Catalog
  alias Jidoka.Operation.Source.Local

  test "local sources compile operation specs and runtime capabilities" do
    source =
      Local.new!(
        operations: [
          %{
            name: "lookup",
            description: "Looks up a value.",
            kind: :tool,
            handler: fn args -> %{value: args["value"]} end
          }
        ]
      )

    assert {:ok, [%Operation{name: "lookup"} = operation]} = Source.operations(source)
    assert operation.metadata["source"] == "local"
    assert operation.metadata["kind"] == :tool
    assert Operation.kind(operation) == :tool

    assert {:ok, %{operations: [^operation], capability: capability}} = Source.compile(source)

    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{"value" => "ada"}})
    assert {:ok, %{value: "ada"}} = capability.(intent, Effect.Journal.new!())
  end

  test "catalog sources search Jido discovered actions" do
    Jido.refresh_discovery()

    source =
      Catalog.new!(
        name: :support,
        only: [:account_lookup],
        max_results: 5
      )

    assert {:ok, [%Operation{name: "catalog_support"} = operation]} = Source.operations(source)
    assert operation.metadata["kind"] == "catalog"
    assert Operation.kind(operation) == :catalog

    assert {:ok, %{capability: capability}} = Source.compile(source)

    intent =
      Effect.Intent.new(:operation, %{
        name: "catalog_support",
        arguments: %{"query" => "account"}
      })

    assert {:ok, %{catalog: "support", count: 1, actions: [action]}} =
             capability.(intent, Effect.Journal.new!())

    assert action.name == "account_lookup"
    assert action.module == "Jidoka.IntegrationSupport.AccountLookupAction"
  end

  test "catalog sources filter discovery by provider, denylist, and runtime limits" do
    Jido.refresh_discovery()

    source =
      Catalog.new!(
        name: "support_ops",
        providers: :support,
        except: "missing_action",
        max_results: 2,
        idempotency: "pure",
        metadata: %{"owner" => "jidoka"}
      )

    assert source.providers == ["support"]
    assert source.except == ["missing_action"]
    assert source.idempotency == :pure

    assert {:ok, [%Operation{} = operation]} = Source.operations(source)
    assert operation.metadata["owner"] == "jidoka"
    assert operation.metadata["providers"] == ["support"]
    assert operation.metadata["max_results"] == 2

    assert {:ok, %{capability: capability}} = Source.compile(source)

    intent =
      Effect.Intent.new(:operation, %{
        name: "catalog_support_ops",
        arguments: %{"limit" => "1"}
      })

    assert {:ok, %{count: 1, actions: [%{name: "account_lookup"}]}} =
             capability.(intent, Effect.Journal.new!())

    invalid_limit =
      Effect.Intent.new(:operation, %{
        name: "catalog_support_ops",
        arguments: %{"limit" => "not-an-int"}
      })

    assert {:ok, %{count: 1, actions: [%{name: "account_lookup"}]}} =
             capability.(invalid_limit, Effect.Journal.new!())

    blocked =
      Catalog.new!(
        name: :blocked_support_ops,
        providers: [:support],
        except: [:account_lookup]
      )

    assert {:ok, %{capability: blocked_capability}} = Source.compile(blocked)

    blocked_intent =
      Effect.Intent.new(:operation, %{
        name: "catalog_blocked_support_ops",
        arguments: %{query: :account}
      })

    assert {:ok, %{count: 0, actions: []}} =
             blocked_capability.(blocked_intent, Effect.Journal.new!())
  end

  test "catalog sources validate input and normalize runtime failures" do
    assert {:error, {:catalog_name, :not_lower_snake, "Bad Name"}} =
             Catalog.new(name: "Bad Name")

    assert {:error, {:invalid_catalog_max_results, 0}} =
             Catalog.new(name: :ops, max_results: 0)

    assert {:error, {:invalid_catalog_idempotency, "eventual"}} =
             Catalog.new(name: :ops, idempotency: "eventual")

    assert {:error, {:invalid_catalog_metadata, []}} =
             Catalog.new(name: :ops, metadata: [])

    assert_raise ArgumentError, ~r/invalid catalog source/, fn ->
      Catalog.new!(name: "Bad Name")
    end

    assert {:ok, source} = Catalog.new(name: :external, via: {:module, String})
    assert {:ok, %{capability: capability}} = Source.compile(source)

    intent = Effect.Intent.new(:operation, %{name: "catalog_external", arguments: %{}})

    assert {:error, {:unsupported_catalog_source, {:module, String}}} =
             capability.(intent, Effect.Journal.new!())

    missing = Effect.Intent.new(:operation, %{name: "catalog_missing", arguments: %{}})

    assert {:error, {:missing_operation_handler, "catalog_missing"}} =
             capability.(missing, Effect.Journal.new!())

    assert {:error, {:unsupported_effect_kind, :llm}} =
             capability.(Effect.Intent.new(:llm, %{}), Effect.Journal.new!())
  end

  test "source compiler routes by unique operation name" do
    first =
      Local.new!(
        operations: [
          %{name: "alpha", handler: fn _args -> %{source: "alpha"} end}
        ]
      )

    second =
      Local.new!(
        operations: [
          %{name: "beta", handler: fn _args -> %{source: "beta"} end}
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} =
             Source.compile([first, second])

    assert Enum.map(operations, & &1.name) == ["alpha", "beta"]

    intent = Effect.Intent.new(:operation, %{name: "beta", arguments: %{}})
    assert {:ok, %{source: "beta"}} = capability.(intent, Effect.Journal.new!())
  end

  test "source compiler rejects duplicate operation names" do
    first = Local.new!(operations: [%{name: "lookup", handler: fn _args -> :first end}])
    second = Local.new!(operations: [%{name: "lookup", handler: fn _args -> :second end}])

    assert {:error, {:duplicate_operation_source_name, "lookup"}} =
             Source.compile([first, second])
  end

  test "local source validates handlers" do
    assert {:error, {:invalid_operation_handler, :not_a_function}} =
             Local.new(operations: [%{name: "lookup", handler: :not_a_function}])
  end
end
