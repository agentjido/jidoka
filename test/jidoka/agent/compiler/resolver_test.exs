defmodule JidokaTest.Agent.Compiler.ResolverTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Compiler.{Context, Resolver}

  defmodule ExampleResolver do
    @behaviour Resolver

    @impl true
    def name, do: :example

    @impl true
    def dsl_paths, do: [[:agent], [:capabilities]]

    @impl true
    def resolve(%Context{} = context) do
      context =
        context
        |> Context.put_value(:result, :resolved)
        |> Context.merge_public_fields(%{result: :resolved})
        |> Context.add_generated_module(Module.concat(context.owner_module, GeneratedTool))
        |> Context.put_runtime_hook(:request_transformer, Module.concat(context.owner_module, RequestTransformer))
        |> Context.merge_imported_spec(%{"capabilities" => %{"tools" => ["example"]}})
        |> Context.put_trace_name(:operation, "example")

      {:ok, context}
    end
  end

  defmodule InvalidResolver do
    @behaviour Resolver

    @impl true
    def name, do: :invalid

    @impl true
    def resolve(_context), do: :bad_result
  end

  test "compiler context tracks resolver-owned output surfaces" do
    context =
      __ENV__
      |> Context.new(owner_module: __MODULE__)
      |> Context.merge_imported_spec(%{"capabilities" => %{"skills" => ["skill"]}})
      |> Context.merge_imported_spec(%{"capabilities" => %{"plugins" => ["plugin"]}})
      |> Context.add_diagnostic(:note)

    assert context.owner_module == __MODULE__
    assert context.imported_spec == %{"capabilities" => %{"skills" => ["skill"], "plugins" => ["plugin"]}}
    assert context.diagnostics == [:note]
  end

  test "resolver behavior runs modules in order" do
    assert Resolver.name(ExampleResolver) == :example
    assert Resolver.dsl_paths(ExampleResolver) == [[:agent], [:capabilities]]

    assert {:ok, context} = Resolver.run([ExampleResolver], Context.new(__ENV__, owner_module: __MODULE__))

    assert context.values.result == :resolved
    assert context.public_fields.result == :resolved
    assert Module.concat(__MODULE__, GeneratedTool) in context.generated_modules
    assert context.runtime_hooks.request_transformer == Module.concat(__MODULE__, RequestTransformer)
    assert context.imported_spec == %{"capabilities" => %{"tools" => ["example"]}}
    assert context.trace_names.operation == "example"
  end

  test "resolver runner reports invalid resolver returns" do
    assert {:error, {InvalidResolver, {:invalid_resolver_result, :bad_result}}} =
             Resolver.run([InvalidResolver], Context.new(__ENV__, owner_module: __MODULE__))
  end
end
