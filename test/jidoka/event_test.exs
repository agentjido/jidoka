defmodule Jidoka.EventTest do
  use ExUnit.Case, async: true

  alias Jidoka.Event

  test "recognizes canonical cancelled turn failure events" do
    assert Event.cancelled?(Event.build(:turn_failed, [], data: %{reason: :cancelled}))
  end

  test "does not classify non-cancelled events as cancellation" do
    refute Event.cancelled?(Event.build(:turn_failed, [], data: %{reason: :boom}))
    refute Event.cancelled?(Event.build(:turn_finished, []))
  end

  test "returns the public failure reason from turn failure events" do
    assert Event.failure_reason(Event.build(:turn_failed, [], data: %{reason: :cancelled})) == :cancelled
    assert Event.failure_reason(Event.build(:turn_failed, [], data: %{reason: :boom})) == :boom
    assert Event.failure_reason(Event.build(:turn_finished, [])) == nil
  end

  test "turn runner emits canonical cancellation failure data" do
    spec =
      Jidoka.agent!(
        id: "event_cancel_agent",
        instructions: "Cancel through the test runtime.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal, _ctx -> {:error, :cancelled} end

    assert {:error, _reason} = Jidoka.turn(spec, "hello", llm: llm, stream_to: self())
    assert_receive {:jidoka_turn_event, %Event{event: :turn_failed, data: %{reason: :cancelled}} = event}
    assert Event.cancelled?(event)
  end
end
