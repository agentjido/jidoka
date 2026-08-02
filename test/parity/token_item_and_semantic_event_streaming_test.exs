defmodule Jidoka.Parity.TokenItemAndSemanticEventStreamingTest do
  use Jidoka.ParityCase, parity: :token_item_and_semantic_event_streaming

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Stream
  alias Jidoka.Turn

  @moduletag :e02

  test "mailbox callback and enumerable consumers receive correlated deltas and lifecycle events" do
    request_id = "parity-e02-stream"
    {:ok, callback_events} = Elixir.Agent.start_link(fn -> [] end)
    on_event = fn event -> Elixir.Agent.update(callback_events, &(&1 ++ [event])) end
    sinks = [stream_to: self(), on_event: on_event]

    llm = fn %Effect.Intent{} = intent, _journal, _context ->
      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :thinking, delta: "check "}
          ),
          sinks
        )

      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :content, delta: "streamed answer"}
          ),
          sinks
        )

      {:ok, %{type: :final, content: "streamed answer"}}
    end

    request = Turn.Request.new!(input: "Stream this", request_id: request_id)

    assert {:ok, %Turn.Result{content: "streamed answer"}} =
             Jidoka.turn(spec(), request, [llm: llm] ++ sinks)

    mailbox_events =
      request_id
      |> Stream.events(stream_event_timeout_ms: 100)
      |> Enum.to_list()

    callback_values = Elixir.Agent.get(callback_events, & &1)

    assert callback_values == mailbox_events
    assert Enum.all?(mailbox_events, &(&1.request_id == request_id))

    assert [thinking_delta, content_delta] =
             Enum.filter(mailbox_events, &(&1.event == :llm_delta))

    assert Stream.thinking_delta(thinking_delta) == "check "
    assert Stream.text_delta(content_delta) == "streamed answer"

    names = Enum.map(mailbox_events, & &1.event)

    assert before?(names, :turn_started, :prompt_assembled)
    assert before?(names, :capability_call_started, :llm_delta)
    assert before?(names, :llm_delta, :capability_call_completed)
    assert before?(names, :effect_completed, :turn_finished)

    assert [%Event{event: :turn_finished, status: :completed}] =
             Enum.filter(mailbox_events, &Stream.terminal?/1)
  end

  defp before?(events, left, right) do
    Enum.find_index(events, &(&1 == left)) < Enum.find_index(events, &(&1 == right))
  end

  defp spec do
    Agent.Spec.new!(
      id: "parity_streaming_agent",
      instructions: "Stream the deterministic answer.",
      model: %{provider: :test, id: "scripted-model"}
    )
  end
end
