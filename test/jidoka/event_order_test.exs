defmodule Jidoka.EventOrderTest do
  use ExUnit.Case, async: true

  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Stream

  test "accepts one contiguous request stream with one terminal event" do
    events = [
      event(:turn_started, 0),
      event(:llm_delta, 1),
      event(:turn_finished, 2)
    ]

    assert :ok = Order.validate(events)
    assert Order.terminal?(List.last(events))
  end

  test "rejects reorder, mixed requests, missing terminals, and events after a terminal event" do
    assert {:error, {:unexpected_sequence, 1, 2}} =
             Order.validate([event(:turn_started, 0), event(:llm_delta, 2)])

    assert {:error, {:mixed_request_id, "ordered-request", "other-request", 1}} =
             Order.validate([
               event(:turn_started, 0),
               Event.build(:turn_finished, [], request_id: "other-request", seq: 1)
             ])

    assert {:error, {:event_after_terminal, 2}} =
             Order.validate([
               event(:turn_started, 0),
               event(:turn_finished, 1),
               event(:llm_delta, 2)
             ])

    assert {:error, :missing_terminal} = Order.validate([event(:turn_started, 0), event(:llm_delta, 1)])
  end

  test "classifies events that cannot join the request sequence" do
    owner = event(:turn_started, 0)
    assert :accept = Order.classify(owner, "ordered-request")

    assert {:reject, :foreign_request_id} =
             Order.classify(
               Event.build(:llm_delta, [], request_id: "other-request", seq: 1),
               "ordered-request"
             )

    assert {:reject, :missing_request_id} =
             Order.classify(Event.build(:llm_delta, [], seq: 1), "ordered-request")
  end

  test "the async controller restamps worker events in mailbox order" do
    events =
      collect_request_events("controller-order", fn opts ->
        :ok = Stream.emit(Event.build(:turn_started, [], request_id: "controller-order", seq: 40), opts)
        :ok = Stream.emit(Event.build(:llm_delta, [], request_id: "controller-order", seq: 2), opts)
        {:ok, "done"}
      end)

    assert Enum.map(events, & &1.seq) == Enum.to_list(0..(length(events) - 1))
    assert :ok = Order.validate(events)
    assert Enum.count(events, &Order.terminal?/1) == 1
  end

  test "foreign and late events cannot create a second terminal result" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :ordered_target,
               "Reject extras",
               [stream: true, request_id: "controller-reject"],
               fn opts ->
                 send(parent, {:controller, Keyword.fetch!(opts, :stream_to)})

                 :ok =
                   Stream.emit(
                     Event.build(:turn_started, [], request_id: "controller-reject", seq: 0),
                     opts
                   )

                 receive do
                   :continue -> {:ok, "done"}
                 end
               end
             )

    assert_receive {:controller, controller}, 1_000

    send(
      controller,
      {:jidoka_turn_event, Event.build(:turn_failed, [], request_id: "foreign-request", seq: 99)}
    )

    send(request.task.pid, :continue)

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)
    assert {:ok, "done"} = Jidoka.await(request, timeout: 1_000)
    events = Enum.to_list(stream)

    send(
      request.controller,
      {:jidoka_turn_event, Event.build(:turn_failed, [], request_id: "controller-reject", seq: 0)}
    )

    assert Enum.count(events, &Order.terminal?/1) == 1
    assert :ok = Order.validate(events)
    refute Enum.any?(events, &(&1.request_id == "foreign-request"))
  end

  test "completion and cancellation races produce one terminal result" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :ordered_target,
               "Race cancel",
               [stream: true, request_id: "controller-cancel-race"],
               fn _opts ->
                 send(parent, {:worker, self()})
                 Process.sleep(:infinity)
               end
             )

    assert_receive {:worker, _worker}, 1_000
    stream = Jidoka.stream(request, stream_event_timeout_ms: 200)
    assert {:ok, _cancellation} = Jidoka.cancel(request, grace_ms: 5)
    assert {:cancelled, _cancellation} = Jidoka.await(request, timeout: 1_000)
    events = Enum.to_list(stream)

    assert Enum.count(events, &Order.terminal?/1) == 1
    assert :ok = Order.validate(events)
  end

  test "request timeout races produce one terminal result" do
    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :ordered_target,
               "Race timeout",
               [stream: true, request_id: "controller-timeout-race", request_timeout_ms: 20],
               fn _opts -> Process.sleep(:infinity) end
             )

    stream = Jidoka.stream(request, stream_event_timeout_ms: 200)
    assert {:error, :request_timeout} = Jidoka.await(request, timeout: 1_000)
    events = Enum.to_list(stream)

    assert Enum.count(events, &Order.terminal?/1) == 1
    assert List.last(events).data.reason == inspect(:request_timeout)
    assert :ok = Order.validate(events)
  end

  test "request timeout resolves a pending cancellation call" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :ordered_target,
               "Timeout during cancellation",
               [request_id: "controller-cancel-timeout", request_timeout_ms: 100],
               fn _opts ->
                 send(parent, :cancel_timeout_worker_started)
                 Process.sleep(:infinity)
               end
             )

    assert_receive :cancel_timeout_worker_started, 1_000
    cancellation = Task.async(fn -> Jidoka.cancel(request, grace_ms: 1_000) end)

    assert {:error, :request_already_finished} = Task.await(cancellation, 1_000)
    assert {:error, :request_timeout} = Jidoka.await(request, timeout: 1_000)
  end

  test "owner exit races produce one terminal result" do
    parent = self()

    owner =
      spawn(fn ->
        assert {:ok, request} =
                 Jidoka.Chat.Async.start_fun(
                   :ordered_target,
                   "Race owner",
                   [stream: true, request_id: "controller-owner-race", stream_to: parent],
                   fn _opts ->
                     send(parent, {:owner_worker, self()})
                     Process.sleep(:infinity)
                   end
                 )

        send(parent, {:owner_request, request})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_request, _request}, 1_000
    assert_receive {:owner_worker, worker}, 1_000
    Process.exit(owner, :kill)
    assert_receive {:jidoka_turn_event, %Event{event: terminal} = event}, 1_000
    assert Order.terminal?(event)
    assert terminal == :turn_failed
    refute_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 100
    refute_receive {:jidoka_turn_event, %Event{event: :turn_failed}}, 100
    refute_receive {:jidoka_turn_event, %Event{event: :turn_hibernated}}, 100
    assert event.request_id == "controller-owner-race"
    assert event.data.reason == inspect(:owner_exited)
    refute eventually_alive?(worker)
  end

  defp collect_request_events(request_id, fun) do
    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :ordered_target,
               "Order this",
               [stream: true, request_id: request_id],
               fun
             )

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)
    assert {:ok, "done"} = Jidoka.await(request, timeout: 1_000)
    Enum.to_list(stream)
  end

  defp event(name, seq) do
    Event.build(name, [], request_id: "ordered-request", seq: seq)
  end

  defp eventually_alive?(pid, attempts \\ 20)
  defp eventually_alive?(pid, 0), do: Process.alive?(pid)

  defp eventually_alive?(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      eventually_alive?(pid, attempts - 1)
    else
      false
    end
  end
end
