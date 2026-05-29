defmodule Jidoka.Runtime.LocalOperationsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Effect

  test "executes arity-one handlers with decoded operation arguments" do
    capability =
      LocalOperations.operations(%{
        weather: fn arguments -> %{city: arguments["city"], condition: "sunny"} end
      })

    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{"city" => "Paris"}})

    assert {:ok, %{city: "Paris", condition: "sunny"}} =
             capability.(intent, Effect.Journal.new!())
  end

  test "executes arity-two handlers with the full intent and journal" do
    capability =
      LocalOperations.operations(%{
        "weather" => fn intent, %Effect.Journal{} ->
          {:error, {:blocked, intent.payload.name}}
        end
      })

    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})

    assert {:error, {:blocked, "weather"}} = capability.(intent, Effect.Journal.new!())
  end

  test "reports missing and invalid operation handlers" do
    missing = LocalOperations.operations(%{})
    invalid = LocalOperations.operations(%{weather: :not_a_function})
    intent = Effect.Intent.new(:operation, %{name: "weather", arguments: %{}})

    assert {:error, {:missing_operation_handler, "weather"}} =
             missing.(intent, Effect.Journal.new!())

    assert {:error, {:invalid_operation_handler, :not_a_function}} =
             invalid.(intent, Effect.Journal.new!())
  end

  test "rejects unsupported effect kinds" do
    capability = LocalOperations.operations(%{})
    intent = Effect.Intent.new(:llm, %{prompt: %{}})

    assert {:error, {:unsupported_effect_kind, :llm}} = capability.(intent, Effect.Journal.new!())
  end
end
