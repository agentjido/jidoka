defmodule Jidoka.StreamTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Event
  alias Jidoka.Stream
  alias Jidoka.Turn

  test "mailbox stream filters by request id and stops on terminal events" do
    request_id = "req_stream_events"

    started = Event.build(:turn_started, [], request_id: request_id)

    delta =
      Event.new!(
        event: :llm_delta,
        request_id: request_id,
        data: %{chunk_type: :content, delta: "hello"}
      )

    thinking =
      Event.new!(
        event: :llm_delta,
        request_id: request_id,
        data: %{chunk_type: :thinking, delta: "checking"}
      )

    terminal = Event.build(:turn_finished, [started, delta, thinking], request_id: request_id)
    unrelated = Event.build(:turn_finished, [], request_id: "other")

    send(self(), {Stream.message_tag(), unrelated})
    send(self(), {Stream.message_tag(), started})
    send(self(), {Stream.message_tag(), delta})
    send(self(), {Stream.message_tag(), thinking})
    send(self(), {Stream.message_tag(), terminal})

    assert Enum.to_list(Stream.events(request_id, stream_event_timeout_ms: 25)) == [
             started,
             delta,
             thinking,
             terminal
           ]

    assert Stream.text_delta(delta) == "hello"
    assert Stream.thinking_delta(thinking) == "checking"
    assert Stream.text_delta(terminal) == nil
    assert Stream.terminal?(terminal)
  end

  test "run_turn publishes lifecycle events without changing durable timeline start" do
    spec =
      Agent.Spec.new!(
        id: "stream_agent",
        instructions: "Answer tersely.",
        model: %{provider: :test, id: "model"}
      )

    llm = fn _intent, _journal ->
      {:ok, %{type: :final, content: "stream ok"}}
    end

    request = Turn.Request.new!(input: "Hello", request_id: "req_stream_turn")

    assert {:ok, %Turn.Result{} = result} =
             Jidoka.run_turn(spec, request, llm: llm, stream_to: self())

    assert_receive {tag, %Event{event: :turn_started, request_id: "req_stream_turn"}}
    assert tag == Stream.message_tag()
    assert_receive {^tag, %Event{event: :prompt_assembled, request_id: "req_stream_turn"}}
    assert_receive {^tag, %Event{event: :turn_finished, request_id: "req_stream_turn"}}

    assert result.content == "stream ok"
    assert [%Event{event: :prompt_assembled} | _events] = result.events
  end

  test "runtime lifecycle events are published before capability-owned deltas" do
    spec =
      Agent.Spec.new!(
        id: "ordered_stream_agent",
        instructions: "Answer tersely.",
        model: %{provider: :test, id: "model"}
      )

    sink = self()

    llm = fn intent, _journal ->
      Event.new!(
        event: :llm_delta,
        request_id: intent.payload.request_id,
        effect_id: intent.id,
        effect_kind: :llm,
        data: %{chunk_type: :content, delta: "ordered"}
      )
      |> Stream.emit(stream_to: sink)

      {:ok, %{type: :final, content: "ordered"}}
    end

    request = Turn.Request.new!(input: "Hello", request_id: "req_ordered_stream")

    assert {:ok, %Turn.Result{content: "ordered"}} =
             Jidoka.run_turn(spec, request, llm: llm, stream_to: self())

    tag = Stream.message_tag()

    events =
      Elixir.Stream.repeatedly(fn ->
        receive do
          {^tag, %Event{request_id: "req_ordered_stream"} = event} -> event
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))
      |> Enum.map(& &1.event)

    assert events == [
             :turn_started,
             :prompt_assembled,
             :effect_planned,
             :effect_started,
             :capability_call_started,
             :llm_delta,
             :capability_call_completed,
             :effect_completed,
             :turn_finished
           ]
  end
end
