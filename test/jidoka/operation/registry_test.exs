defmodule Jidoka.Operation.RegistryTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Registry
  alias Jidoka.Operation.Registry.Capability

  test "merges static and extension operations in declaration order" do
    static = operation("lookup")
    extension = operation("coding.read")

    assert {:ok, registry} = Registry.new([static], [extension])
    assert Enum.map(Registry.operations(registry), & &1.name) == ["lookup", "coding.read"]
    assert Registry.extension?(registry, "coding.read")
    refute Registry.extension?(registry, "lookup")
  end

  test "rejects duplicate names across static and extension operations" do
    assert {:error, {:duplicate_operation_name, "lookup"}} =
             Registry.new([operation("lookup")], [operation("lookup")])
  end

  test "validates and normalizes arguments against the declared JSON Schema" do
    registry = Registry.new!([operation("lookup")])

    assert {:ok, %{"query" => "Ada"}} =
             Registry.validate_arguments(registry, "lookup", %{query: "Ada"})

    assert {:error, {:invalid_operation_arguments, "lookup", _reason}} =
             Registry.validate_arguments(registry, "lookup", %{})

    assert {:error, {:invalid_operation_arguments, "lookup", _reason}} =
             Registry.validate_arguments(registry, "lookup", %{"query" => "Ada", "extra" => true})
  end

  test "validates before routing static and extension handlers" do
    test_pid = self()
    static_operation = operation("lookup")
    extension_operation = operation("coding.read")
    registry = Registry.new!([static_operation], [extension_operation])

    static = fn intent, _journal, _context ->
      send(test_pid, {:static_called, intent.payload})
      {:ok, :static}
    end

    extension = fn intent, _journal, _context ->
      send(test_pid, {:extension_called, intent.payload})
      {:ok, :extension}
    end

    capability = Capability.wrap(registry, static, extension)
    journal = Effect.Journal.new!()
    context = Jidoka.Context.from_data!(%{})

    invalid = Effect.Intent.new(:operation, %{name: "coding.read", arguments: %{}})

    assert {:error, {:invalid_operation_arguments, "coding.read", _reason}} =
             capability.(invalid, journal, context)

    refute_received {:extension_called, _payload}

    valid = Effect.Intent.new(:operation, %{name: "coding.read", arguments: %{query: "lib"}})
    assert {:ok, :extension} = capability.(valid, journal, context)
    assert_received {:extension_called, %{arguments: %{"query" => "lib"}}}

    static_intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{query: "Ada"}})
    assert {:ok, :static} = capability.(static_intent, journal, context)
    assert_received {:static_called, %{arguments: %{"query" => "Ada"}}}
  end

  test "prompt projection uses the same registry schema" do
    registry = Registry.new!([operation("lookup")])

    assert [contract] = Registry.prompt_operations(registry)
    assert contract.name == "lookup"
    assert contract.parameters_schema["required"] == ["query"]
    assert contract.parameters_schema["additionalProperties"] == false
  end

  defp operation(name) do
    Operation.new!(
      name: name,
      description: "Find a value.",
      idempotency: :pure,
      metadata: %{
        "parameters_schema" => %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"],
          "additionalProperties" => false
        }
      }
    )
  end
end
