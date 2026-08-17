defmodule Jidoka.RequestControllerCleanupTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Cancellation.Token
  alias Jidoka.Chat.Request
  alias Jidoka.Event
  alias Jidoka.Event.Order
  alias Jidoka.Session
  alias Jidoka.Session.Sequence
  alias Jidoka.Session.Sequence.Request, as: SequenceRequest
  alias Jidoka.Turn

  test "chat request handles require a controller" do
    invalid =
      struct(Request,
        request_id: "invalid-controller",
        controller: nil,
        target: :invalid,
        session_id: nil,
        stream_to: nil,
        started_at_ms: 0,
        metadata: %{}
      )

    assert {:error, :invalid_async_request} = Jidoka.Chat.Async.await(invalid)
    assert {:error, :invalid_async_request} = Jidoka.Chat.Async.cancel(invalid)

    assert_raise ArgumentError, fn ->
      Request.new(request_id: "missing-controller", target: :invalid, started_at_ms: 0)
    end
  end

  test "cancel and await use one controller and terminal cleanup drops runtime references" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :controller_only,
               "Cancel",
               [request_id: "controller-only", request_retention_ms: 1_000],
               fn _opts ->
                 send(parent, {:controller_worker, self()})

                 receive do
                   :finish -> {:ok, "ignored after cancellation"}
                 end
               end
             )

    assert_receive {:controller_worker, worker}, 1_000
    awaiter = Task.async(fn -> Jidoka.await(request, timeout: 1_000) end)
    assert controller_state(request.controller, &(&1.awaiters != []))

    canceller = Task.async(fn -> Jidoka.cancel(request, grace_ms: 500) end)

    assert controller_state(
             request.controller,
             &(&1.awaiters != [] and &1.cancellers != [] and &1.cancellation_requested?)
           )

    send(worker, :finish)

    assert {:ok, cancellation} = Task.await(canceller, 1_000)
    assert {:cancelled, ^cancellation} = Task.await(awaiter, 1_000)

    state = :sys.get_state(request.controller)
    assert state.status == :finished
    assert state.task == nil
    assert state.token == nil
    assert state.stream_to == nil
    assert state.on_event == nil
    assert state.on_cancelled == nil
    assert state.publisher_opts == nil
    assert state.awaiters == []
    assert state.cancellers == []
    assert state.cancellation_members == %{}
  end

  test "a completed chat controller expires and stops registered members" do
    parent = self()
    member = spawn(fn -> Process.sleep(:infinity) end)
    member_monitor = Process.monitor(member)
    on_exit(fn -> if Process.alive?(member), do: Process.exit(member, :kill) end)

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :cleanup_target,
               "Complete",
               [request_id: "cleanup-complete", request_retention_ms: 10],
               fn opts ->
                 :ok = Token.register(Keyword.fetch!(opts, :cancellation), member)
                 send(parent, {:registered_member, member})
                 {:ok, "done"}
               end
             )

    controller_monitor = Process.monitor(request.controller)
    assert_receive {:registered_member, ^member}, 1_000
    assert {:ok, "done"} = Jidoka.await(request, timeout: 1_000)
    assert {:ok, "done"} = Jidoka.await(request, timeout: 100)
    assert {:error, :request_already_finished} = Jidoka.cancel(request)

    assert_receive {:DOWN, ^member_monitor, :process, ^member, :killed}, 1_000
    assert_receive {:DOWN, ^controller_monitor, :process, _pid, :normal}, 1_000
    assert {:error, :request_expired} = Jidoka.await(request)
    assert {:error, :request_expired} = Jidoka.cancel(request)
  end

  test "a terminal event waits for the matching worker result" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :cleanup_target,
               "Defer terminal",
               [
                 stream: true,
                 request_id: "cleanup-terminal-result",
                 request_timeout_ms: 100
               ],
               fn opts ->
                 :ok =
                   Jidoka.Stream.emit(
                     Event.build(:turn_finished, [], request_id: "cleanup-terminal-result"),
                     opts
                   )

                 send(parent, :terminal_candidate_sent)
                 Process.sleep(:infinity)
               end
             )

    assert_receive :terminal_candidate_sent, 1_000
    refute_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 20

    assert {:error, :request_timeout} = Jidoka.await(request, timeout: 1_000)
    assert_receive {:jidoka_turn_event, %Event{event: :turn_failed} = event}, 1_000
    assert event.data.reason == inspect(:request_timeout)
    refute_receive {:jidoka_turn_event, %Event{event: :turn_finished}}, 20
  end

  test "small retention cannot expire a chat controller before its startup handshake" do
    for index <- 1..25 do
      assert {:ok, request} =
               Jidoka.Chat.Async.start_fun(
                 :cleanup_target,
                 "Fast completion",
                 [request_id: "cleanup-startup-#{index}", request_retention_ms: 1],
                 fn _opts -> {:ok, index} end
               )

      assert request.request_id == "cleanup-startup-#{index}"
    end
  end

  test "error, timeout, and worker-exit controllers expire within the same bound" do
    for {name, fun, expected} <- [
          {:rejection, fn _opts -> {:error, :policy_denied} end, {:error, :policy_denied}},
          {:worker_exit, fn _opts -> raise "worker failed" end, :worker_exit},
          {:timeout, fn _opts -> Process.sleep(:infinity) end, {:error, :request_timeout}}
        ] do
      opts = [request_id: "cleanup-#{name}", request_retention_ms: 10]
      opts = if name == :timeout, do: Keyword.put(opts, :request_timeout_ms, 15), else: opts

      assert {:ok, request} =
               Jidoka.Chat.Async.start_fun(:cleanup_target, "Stop", opts, fun)

      monitor = Process.monitor(request.controller)
      result = Jidoka.await(request, timeout: 1_000)

      case expected do
        :worker_exit -> assert {:error, {:chat_request_failed, _reason}} = result
        expected_result -> assert result == expected_result
      end

      assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
    end
  end

  test "forced cancellation stops the worker and expires the controller" do
    parent = self()

    assert {:ok, request} =
             Jidoka.Chat.Async.start_fun(
               :cleanup_cancel,
               "Cancel",
               [request_id: "cleanup-cancel", request_retention_ms: 10, stream: true],
               fn _opts ->
                 send(parent, {:cleanup_worker, self()})
                 Process.sleep(:infinity)
               end
             )

    assert_receive {:cleanup_worker, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    controller_monitor = Process.monitor(request.controller)
    stream = Jidoka.stream(request, stream_event_timeout_ms: 200)

    assert {:ok, _cancellation} = Jidoka.cancel(request, grace_ms: 5)
    assert {:cancelled, _cancellation} = Jidoka.await(request, timeout: 100)
    events = Enum.to_list(stream)
    assert Enum.count(events, &Order.terminal?/1) == 1

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^controller_monitor, :process, _pid, :normal}, 1_000
  end

  test "owner exit stops the controller without leaving a live handle" do
    parent = self()

    owner =
      spawn(fn ->
        assert {:ok, request} =
                 Jidoka.Chat.Async.start_fun(
                   :cleanup_owner,
                   "Owner",
                   [request_id: "cleanup-owner", stream_to: parent],
                   fn _opts -> Process.sleep(:infinity) end
                 )

        send(parent, {:owned, request})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned, request}, 1_000
    monitor = Process.monitor(request.controller)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 1_000
    assert_receive {:jidoka_turn_event, %Event{} = event}, 1_000
    assert Order.terminal?(event)
    refute_receive {:jidoka_turn_event, %Event{event: :turn_failed}}, 50
    assert {:error, :request_expired} = Jidoka.await(request)
  end

  test "a completed sequence controller also expires" do
    assert {:ok, session} = Session.start(spec(), "cleanup-sequence")

    assert {:ok, request} =
             Session.run_sequence_async(
               session,
               [Turn.Request.new!(input: "Complete", request_id: "cleanup-sequence-turn")],
               sequence_request_id: "cleanup-sequence-request",
               request_retention_ms: 10,
               llm: fn _intent, _journal, _context ->
                 {:ok, %{type: :final, content: "done"}}
               end
             )

    assert {:ok, controller} = SequenceRequest.controller(request)
    monitor = Process.monitor(controller)
    assert {:ok, %Sequence.Result{status: :completed}} = Jidoka.await(request, timeout: 1_000)
    assert {:ok, %Sequence.Result{status: :completed}} = Jidoka.await(request, timeout: 100)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 1_000
    assert {:error, :request_expired} = Jidoka.await(request)
  end

  defp spec do
    Agent.Spec.new!(
      id: "cleanup_agent",
      instructions: "Complete the bounded cleanup test.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp controller_state(controller, predicate, attempts \\ 100)

  defp controller_state(_controller, _predicate, 0), do: false

  defp controller_state(controller, predicate, attempts) do
    if predicate.(:sys.get_state(controller)) do
      true
    else
      receive do
      after
        5 -> controller_state(controller, predicate, attempts - 1)
      end
    end
  end
end
