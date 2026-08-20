defmodule Jidoka.OperationSourceTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source
  alias Jidoka.Operation.Source.Defined
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

  defmodule InvalidCompiledSource do
    defstruct []
    def compile(%__MODULE__{}, _opts), do: {:ok, :invalid}
  end

  defmodule ErrorCompiledSource do
    defstruct []
    def compile(%__MODULE__{}, _opts), do: {:error, :compile_failed}
  end

  defmodule LegacySource do
    defstruct []

    def operations(%__MODULE__{}, _opts), do: {:ok, [Operation.new!(name: "legacy")]}
    def capability(%__MODULE__{}, _opts), do: {:ok, fn _intent, _journal, _context -> {:ok, :legacy} end}
    def metadata(%__MODULE__{}, _opts), do: {:ok, [%{"source" => "legacy"}]}
  end

  defmodule LegacyNoMetadataSource do
    defstruct []

    def operations(%__MODULE__{}, _opts), do: {:ok, [Operation.new!(name: "legacy_no_metadata")]}
    def capability(%__MODULE__{}, _opts), do: {:ok, fn _intent, _journal, _context -> {:ok, :legacy} end}
  end

  defmodule InvalidLegacySource do
    defstruct []
  end

  defmodule ErrorLegacySource do
    defstruct []
    def operations(%__MODULE__{}, _opts), do: {:error, :operations_failed}
    def capability(%__MODULE__{}, _opts), do: {:error, :not_called}
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

  test "an empty source set has a stable contract digest" do
    assert {:ok, first} = Source.compile([])
    assert {:ok, second} = Source.compile([])

    assert is_binary(first.digest)
    assert first.digest == second.digest
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

  test "defined sources select declared operations and preserve metadata" do
    lookup = Operation.new!(name: "lookup")
    missing = Operation.new!(name: "missing")

    source =
      Local.new!(
        operations: [
          %{name: "lookup", handler: fn _args, _context -> %{found: true} end}
        ]
      )

    defined = Defined.new!(source, [lookup], [%{"owner" => "test"}])

    assert {:ok, [^lookup]} = Source.operations(defined)
    assert {:ok, [%{"owner" => "test"}]} = Source.metadata(defined)
    assert {:ok, capability} = Source.capability(defined)
    assert is_function(capability, 3)

    assert {:ok, %{operations: [^lookup], metadata: [%{"owner" => "test"}]}} =
             Source.compile(defined)

    assert {:error, {:missing_operation_source_route, "missing"}} =
             source
             |> Defined.new!([missing])
             |> Source.compile()
  end

  test "source loading validates compiled and legacy callback contracts" do
    operation = Operation.new!(name: "direct")
    capability = fn _intent, _journal, _context -> {:ok, :direct} end

    assert {:ok, compiled} = Source.compiled([operation], capability)
    assert {:ok, ^compiled} = Source.load(compiled)

    assert {:error, {:invalid_compiled_operation_source, InvalidCompiledSource, :invalid}} =
             Source.load(%InvalidCompiledSource{})

    assert {:error, :compile_failed} = Source.load(%ErrorCompiledSource{})

    assert {:ok, legacy} = Source.load(%LegacySource{})
    assert Enum.map(legacy.operations, & &1.name) == ["legacy"]
    assert legacy.metadata == [%{"source" => "legacy"}]

    assert {:ok, no_metadata} = Source.load(%LegacyNoMetadataSource{})
    assert no_metadata.metadata == []

    assert {:error, {:invalid_operation_source, InvalidLegacySource}} =
             Source.load(%InvalidLegacySource{})

    assert {:error, :operations_failed} = Source.load(%ErrorLegacySource{})
  end
end
