defmodule JidokaTest.InterruptTest do
  use ExUnit.Case, async: true

  test "normalizes maps, keyword data, defaults, and existing structs" do
    interrupt = Jidoka.Interrupt.new(id: "approval-1", kind: "approval", message: "Approve?", data: [amount: 100])

    assert interrupt.id == "approval-1"
    assert interrupt.kind == "approval"
    assert interrupt.message == "Approve?"
    assert interrupt.data == %{amount: 100}
    assert Jidoka.Interrupt.new(interrupt) == interrupt

    defaulted = Jidoka.Interrupt.new(%{"data" => :bad})

    assert byte_size(defaulted.id) > 0
    assert defaulted.kind == :interrupt
    assert defaulted.message == "Jidoka agent interrupted"
    assert defaulted.data == %{}
  end

  test "rejects invalid interrupt input" do
    assert_raise ArgumentError, ~r/expected a map, keyword list, or interrupt struct/, fn ->
      Jidoka.Interrupt.new(:bad)
    end
  end
end
