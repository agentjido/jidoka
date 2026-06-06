defmodule Jidoka.OperationSourceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Local

  test "local sources compile operation specs and runtime capabilities" do
    source =
      Local.new!(
        operations: [
          %{
            name: "lookup",
            description: "Looks up a value.",
            kind: :tool,
            handler: fn args, _ctx -> %{value: args["value"]} end
          }
        ]
      )

    assert {:ok, [%Operation{name: "lookup"} = operation]} = Source.operations(source)
    assert operation.metadata["source"] == "local"
    assert operation.metadata["kind"] == :tool
    assert Operation.kind(operation) == :tool

    assert {:ok, %{operations: [^operation], capability: capability}} = Source.compile(source)

    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{"value" => "ada"}})
    assert {:ok, %{value: "ada"}} = capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end

  test "source compiler routes by unique operation name" do
    first =
      Local.new!(
        operations: [
          %{name: "alpha", handler: fn _args, _ctx -> %{source: "alpha"} end}
        ]
      )

    second =
      Local.new!(
        operations: [
          %{name: "beta", handler: fn _args, _ctx -> %{source: "beta"} end}
        ]
      )

    assert {:ok, %{operations: operations, capability: capability}} =
             Source.compile([first, second])

    assert Enum.map(operations, & &1.name) == ["alpha", "beta"]

    intent = Effect.Intent.new(:operation, %{name: "beta", arguments: %{}})
    assert {:ok, %{source: "beta"}} = capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end

  test "source compiler rejects duplicate operation names" do
    first = Local.new!(operations: [%{name: "lookup", handler: fn _args, _ctx -> :first end}])
    second = Local.new!(operations: [%{name: "lookup", handler: fn _args, _ctx -> :second end}])

    assert {:error, {:duplicate_operation_source_name, "lookup"}} =
             Source.compile([first, second])
  end

  test "local source validates handlers" do
    assert {:error, {:invalid_operation_handler, :not_a_function}} =
             Local.new(operations: [%{name: "lookup", handler: :not_a_function}])
  end
end
