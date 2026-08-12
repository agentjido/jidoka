defmodule Jidoka.Extension.EventTest do
  use ExUnit.Case, async: true

  alias Jidoka.Extension.{Dispatcher, Event, RuntimeEvents}

  test "builds every protocol-v1 event as bounded redacted JSON data" do
    for {name, index} <- Enum.with_index(Event.names()) do
      assert {:ok, event} =
               Event.new(
                 %{
                   name: name,
                   session_ref: "session-1",
                   data: %{index: index, api_key: "remove-me", nested: %{password: "remove-me"}}
                 },
                 id_generator: fn -> "event-#{index}" end,
                 clock: fn -> 1_000 + index end
               )

      projection = Event.to_map(event)
      assert projection["name"] == name
      refute Map.has_key?(projection["data"], "api_key")
      refute Map.has_key?(projection["data"]["nested"], "password")
      assert {:ok, _json} = Jason.encode(projection)
    end
  end

  test "rejects unknown, malformed, live, and oversized event data" do
    assert {:error, _reason} = Event.new(%{name: "custom.event"})
    assert {:error, _reason} = Event.new(%{name: "turn.start", session_ref: ""})
    assert {:error, _reason} = Event.new(%{name: "turn.start", data: %{pid: self()}})

    assert {:error, _reason} =
             Event.new(%{name: "turn.start", data: %{value: String.duplicate("x", 65_536)}})
  end

  test "delivers one ordered lifecycle sequence and isolates subscriber failures" do
    owner = self()

    recorder = fn event ->
      send(owner, {:event, event.name})
      :ok
    end

    raiser = fn _event -> raise "subscriber failed" end

    sleeper = fn _event ->
      Process.sleep(100)
      :ok
    end

    malformed = fn _event -> :unexpected end

    {:ok, dispatcher} =
      start_supervised({Dispatcher, subscribers: [raiser, recorder, sleeper, malformed], timeout_ms: 5})

    opts = [
      extension_dispatcher: dispatcher,
      extension_event_id_generator: fn -> "fixed-event" end,
      extension_clock: fn -> 123 end,
      session_id: "session-1"
    ]

    RuntimeEvents.emit("session.start", %{session_ref: "session-1", data: %{}}, opts)
    emit_core(:turn_started, nil, opts)
    emit_core(:capability_call_started, :llm, opts)
    emit_core(:llm_delta, :llm, opts)
    emit_core(:capability_call_completed, :llm, opts)
    emit_core(:capability_call_started, :operation, opts)
    emit_core(:operation_observed, :operation, opts)
    emit_core(:capability_call_completed, :operation, opts)
    emit_core(:turn_finished, nil, opts)
    RuntimeEvents.emit("session.end", %{session_ref: "session-1", data: %{status: :completed}}, opts)

    assert_receive {:event, "session.start"}
    assert_receive {:event, "turn.start"}
    assert_receive {:event, "model.start"}
    assert_receive {:event, "model.update"}
    assert_receive {:event, "model.end"}
    assert_receive {:event, "tool.before"}
    assert_receive {:event, "tool.update"}
    assert_receive {:event, "tool.after"}
    assert_receive {:event, "turn.end"}
    assert_receive {:event, "session.end"}
    refute_receive {:event, _name}

    event = Event.new!(%{name: "turn.update", event_id: "evidence", timestamp_ms: 1})
    assert {:ok, [failed, delivered, timeout, malformed_return]} = Dispatcher.dispatch(dispatcher, event)
    assert failed["status"] == "failed"
    assert delivered["status"] == "delivered"
    assert timeout["status"] == "timeout"
    assert malformed_return["status"] == "malformed_return"
  end

  test "maps cancellation, hibernation, denial, and runtime errors to one terminal path" do
    owner = self()

    {:ok, dispatcher} =
      start_supervised(
        {Dispatcher,
         subscribers: [
           fn event ->
             send(owner, event)
             :ok
           end
         ]}
      )

    opts = [extension_dispatcher: dispatcher, session_id: "session-1"]

    for {core_name, data} <- [
          {:turn_failed, %{reason: :cancelled}},
          {:turn_hibernated, %{reason: :review}},
          {:turn_failed, %{reason: :policy_denied}},
          {:turn_failed, %{reason: :runtime_error}}
        ] do
      RuntimeEvents.emit_runtime(
        Jidoka.Event.build(core_name, [], request_id: "request-1", data: data),
        opts
      )

      assert_receive %Event{name: "turn.end", data: event_data}
      assert event_data["core_event"] == Atom.to_string(core_name)
    end
  end

  defp emit_core(name, effect_kind, opts) do
    attrs = [request_id: "request-1"]
    attrs = if effect_kind, do: Keyword.put(attrs, :effect_kind, effect_kind), else: attrs
    RuntimeEvents.emit_runtime(Jidoka.Event.build(name, [], attrs), opts)
  end
end
