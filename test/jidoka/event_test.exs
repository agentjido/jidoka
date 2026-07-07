defmodule Jidoka.EventTest do
  use ExUnit.Case, async: true

  alias Jidoka.Event
  alias Jidoka.Turn

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

  test "accepts atom-keyed event data" do
    assert {:ok, %Event{data: %{reason: :cancelled}}} =
             Event.new(event: :turn_failed, data: %{reason: :cancelled})
  end

  test "accepts string-keyed event attrs while enforcing atom-keyed data" do
    assert {:ok, %Event{event: :turn_failed, data: %{reason: :cancelled}}} =
             Event.new(%{"event" => "turn_failed", "data" => %{reason: :cancelled}})

    assert {:error, errors} =
             Event.new(%{"event" => "turn_failed", "data" => %{"reason" => :cancelled}})

    assert invalid_event_data_key_error?(errors, "reason")
  end

  test "accepts string-keyed maps nested inside event data values" do
    assert {:ok, %Event{data: %{payload: %{"external" => true}}}} =
             Event.new(event: :turn_failed, data: %{payload: %{"external" => true}})
  end

  test "rejects string-keyed event data" do
    assert {:error, errors} = Event.new(event: :turn_failed, data: %{"reason" => :cancelled})
    assert invalid_event_data_key_error?(errors, "reason")
  end

  test "raises with an invalid event label for string-keyed event data" do
    assert_raise ArgumentError, ~r/event data keys must be atoms/, fn ->
      Event.new!(event: :turn_failed, data: %{"reason" => :cancelled})
    end
  end

  test "build enforces atom-keyed event data" do
    assert_raise ArgumentError, ~r/event data keys must be atoms/, fn ->
      Event.build(:turn_failed, [], data: %{"reason" => :cancelled})
    end
  end

  test "event schema consumers enforce atom-keyed event data" do
    assert {:error, errors} =
             Turn.Transition.new(%{},
               events: [%{event: :turn_failed, data: %{"reason" => :cancelled}}]
             )

    assert invalid_event_data_key_error?(errors, "reason")
  end

  defp invalid_event_data_key_error?(errors, key) when is_list(errors) do
    Enum.any?(errors, &invalid_event_data_key_error?(&1, key))
  end

  defp invalid_event_data_key_error?(%Zoi.Error{message: message}, key) do
    message == "event data keys must be atoms, got: #{inspect(key)}"
  end

  defp invalid_event_data_key_error?(_error, _key), do: false
end
