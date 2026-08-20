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

  test "rejects invalid registry and operation inputs" do
    assert {:error, {:invalid_operation_registry, :invalid, []}} = Registry.new(:invalid, [])
    assert {:error, {:invalid_registry_operation, 0, _reason}} = Registry.new([:invalid])

    assert_raise ArgumentError, ~r/invalid operation registry/, fn ->
      Registry.new!([:invalid])
    end
  end

  test "marks only matching declared extension contracts" do
    %Operation{} = operation = operation("lookup")
    registry = Registry.new!([operation])

    assert {:ok, marked} = Registry.mark_extensions(registry, [operation])
    assert Registry.extension?(marked, "lookup")

    changed = %Operation{operation | description: "Changed"}

    assert {:error, {:operation_source_contract_mismatch, "lookup"}} =
             Registry.mark_extensions(registry, [changed])

    assert {:error, {:unknown_operation, "missing"}} =
             Registry.mark_extensions(registry, [Operation.new!(name: "missing")])
  end

  test "rejects malformed schemas and JSON argument values" do
    invalid_schema = Operation.new!(name: "invalid", metadata: %{parameters_schema: "bad"})

    assert {:error, {:invalid_operation_parameter_schema, "invalid", "bad"}} =
             Registry.new([invalid_schema])

    invalid_json_schema =
      Operation.new!(name: "invalid_json", metadata: %{parameters_schema: %{1 => self()}})

    assert {:error, {:invalid_operation_parameter_schema, "invalid_json", %ArgumentError{}}} =
             Registry.new([invalid_json_schema])

    registry = Registry.new!([Operation.new!(name: "plain")])

    assert {:error, {:invalid_operation_arguments, 123}} =
             Registry.validate_arguments(registry, "plain", 123)

    assert {:error, {:invalid_operation_arguments, {:invalid_json_key, 1}}} =
             Registry.validate_arguments(registry, "plain", %{1 => "bad"})

    assert {:error, {:invalid_operation_arguments, {:invalid_json_value, _pid}}} =
             Registry.validate_arguments(registry, "plain", %{pid: self()})

    assert {:error, {:invalid_operation_arguments, {:duplicate_json_key, "same"}}} =
             Registry.validate_arguments(registry, "plain", %{"same" => 2, same: 1})

    assert {:error, {:invalid_operation_arguments, {:invalid_json_value, _pid}}} =
             Registry.validate_arguments(registry, "plain", %{values: [1, self()]})
  end

  test "applies nested object and array schema defaults" do
    operation =
      Operation.new!(
        name: "defaults",
        metadata: %{
          parameters_schema: %{
            "type" => "object",
            "properties" => %{
              "settings" => %{
                "type" => "object",
                "default" => %{},
                "properties" => %{"enabled" => %{"type" => "boolean", "default" => true}}
              },
              "items" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{"count" => %{"type" => "integer", "default" => 1}}
                }
              }
            }
          }
        }
      )

    registry = Registry.new!([operation])

    assert {:ok,
            %{
              "settings" => %{"enabled" => true},
              "items" => [%{"count" => 1}, %{"count" => 2}]
            }} =
             Registry.validate_arguments(registry, "defaults", %{
               items: [%{}, %{count: 2}]
             })
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
