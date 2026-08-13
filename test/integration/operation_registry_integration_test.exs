defmodule Jidoka.OperationRegistryIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Operation.Source.Local
  alias Jidoka.Turn.Execution

  test "turn preparation merges built-in and extension source operations into one registry" do
    test_pid = self()
    static_operation = operation("lookup")

    spec =
      Agent.Spec.new!(
        id: "registry-agent",
        instructions: "Use tools.",
        model: %{provider: :test, id: "model"},
        operations: [static_operation]
      )

    extension_source =
      Local.new!(
        operations: [
          %{
            name: "extension_lookup",
            description: "Look up extension data.",
            idempotency: :pure,
            metadata: static_operation.metadata,
            handler: fn arguments, _context ->
              send(test_pid, {:extension_called, arguments})
              %{source: :extension}
            end
          }
        ]
      )

    static_capability = fn _intent, _journal, _context -> {:ok, %{source: :static}} end
    llm = fn _intent, _journal, _context -> {:ok, Effect.LLMDecision.final("unused")} end

    assert {:ok, prepared} =
             Execution.prepare(spec, "Find Ada",
               llm: llm,
               operations: static_capability,
               operation_sources: [extension_source]
             )

    assert Enum.map(prepared.plan.spec.operations, & &1.name) == ["lookup", "extension_lookup"]

    intent =
      Effect.Intent.new(:operation, %{
        name: "extension_lookup",
        arguments: %{"query" => "Ada"}
      })

    assert {:ok, %{source: :extension}} =
             prepared.capabilities.operations.(
               intent,
               Effect.Journal.new!(),
               Jidoka.Context.from_data!(%{})
             )

    assert_received {:extension_called, %{"query" => "Ada"}}
  end

  defp operation(name) do
    Operation.new!(
      name: name,
      description: "Look up data.",
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
