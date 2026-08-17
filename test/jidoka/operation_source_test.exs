defmodule Jidoka.OperationSourceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Local

  defmodule ChangingSource do
    @moduledoc false

    @behaviour Jidoka.Operation.Source

    alias Jidoka.Agent.Spec.Operation
    alias Jidoka.Operation.Source.Compiled

    defstruct []

    @impl true
    def compile(%__MODULE__{}, _opts) do
      version = Process.get({__MODULE__, :compile_count}, 0) + 1
      Process.put({__MODULE__, :compile_count}, version)
      name = "changing_#{version}"
      operation = Operation.new!(name: name, metadata: %{"version" => version})
      route = fn _intent, _journal, _context -> {:ok, %{version: version}} end
      Compiled.new([operation], %{name => route}, [%{"version" => version}])
    end
  end

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

  test "one changing source compilation returns internally matching views" do
    Process.put({ChangingSource, :compile_count}, 0)

    assert {:ok, compiled} = Source.compile(%ChangingSource{})

    assert Process.get({ChangingSource, :compile_count}) == 1
    assert Enum.map(compiled.operations, & &1.name) == ["changing_1"]
    assert Map.keys(compiled.routes_by_name) == ["changing_1"]
    assert compiled.metadata == [%{"version" => 1}]

    intent = Effect.Intent.new(:operation, %{name: "changing_1", arguments: %{}})

    assert {:ok, %{version: 1}} =
             compiled.capability.(intent, Effect.Journal.new!(), Jidoka.Context.from_data!(%{}))
  end

  test "compiled sources require one route for every advertised operation" do
    operation = Operation.new!(name: "advertised")
    route = fn _intent, _journal, _context -> {:ok, :unexpected} end

    assert {:error, {:missing_operation_source_route, "advertised"}} =
             Jidoka.Operation.Source.Compiled.new([operation], %{}, [])

    assert {:error, {:unadvertised_operation_source_route, "extra"}} =
             Jidoka.Operation.Source.Compiled.new(
               [operation],
               %{"advertised" => route, "extra" => route},
               []
             )
  end
end
