defmodule Jidoka.Runtime.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Jidoka.Effect
  alias Jidoka.Runtime.Capabilities

  test "requires an llm capability" do
    assert {:error, [%Zoi.Error{path: [:llm]}]} = Capabilities.new(%{})
  end

  test "provides a default missing operations capability" do
    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end

    assert {:ok, %Capabilities{} = capabilities} = Capabilities.new(llm: llm)

    intent = Effect.Intent.new(:operation, %{name: "missing", arguments: %{}})

    assert {:error, :missing_operations_capability} =
             capabilities.operations.(intent, Effect.Journal.new!())
  end

  test "accepts string-keyed capability maps" do
    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "ok"}} end
    operations = fn _intent, _journal -> {:ok, %{ok: true}} end

    assert {:ok, %Capabilities{llm: ^llm, operations: ^operations}} =
             Capabilities.new(%{"llm" => llm, "operations" => operations})
  end
end
