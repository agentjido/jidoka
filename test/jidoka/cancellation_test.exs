defmodule Jidoka.CancellationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Chat.Request
  alias Jidoka.Event
  alias Jidoka.Session.Data, as: SessionData
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.Stream

  test "an active request cancels cooperatively with one typed terminal event" do
    parent = self()

    llm = fn _intent, _journal, context ->
      send(parent, {:capability_started, self(), Cancellation.requested?(context)})
      :ok = wait_for_cancellation(context, 1_000)
      send(parent, {:capability_cleaned_up, self()})
      {:error, :cancelled}
    end

    assert {:ok, request} =
             Jidoka.chat_async(spec(), "Cancel this",
               llm: llm,
               stream: true,
               request_id: "req_cooperative_cancel"
             )

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)

    assert_receive {:capability_started, capability_pid, false}, 1_000

    assert {:ok,
            %Cancellation{
              request_id: "req_cooperative_cancel",
              forced?: false,
              reason: :cancelled
            } = cancellation} = Jidoka.cancel(request, grace_ms: 500)

    assert {:cancelled, ^cancellation} = Jidoka.await(request, timeout: 100)
    assert_receive {:capability_cleaned_up, ^capability_pid}, 1_000
    refute Process.alive?(request.task.pid)
    refute Process.alive?(capability_pid)

    events = Enum.to_list(stream)
    terminal_events = Enum.filter(events, &Stream.terminal?/1)

    assert [%Event{event: :turn_failed, data: %{reason: :cancelled}} = terminal] = terminal_events
    assert Event.cancelled?(terminal)
    refute Enum.any?(events, &match?(%Event{event: :turn_finished}, &1))
  end

  test "a non-cooperative request uses bounded forced cancellation" do
    parent = self()

    assert {:ok, request} =
             Request.start_fun(
               :forced_cancel_target,
               "Cancel this",
               [stream: true, request_id: "req_forced_cancel"],
               fn _opts ->
                 send(parent, {:request_started, self()})
                 Process.sleep(5_000)
                 {:ok, "too late"}
               end
             )

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)
    assert_receive {:request_started, worker_pid}, 1_000

    assert {:ok, %Cancellation{forced?: true} = cancellation} =
             Jidoka.cancel(request, grace_ms: 5)

    assert {:cancelled, ^cancellation} = Jidoka.await(request, timeout: 100)
    refute Process.alive?(worker_pid)

    assert [%Event{event: :turn_failed, data: %{reason: :cancelled, forced: true}}] =
             stream
             |> Enum.to_list()
             |> Enum.filter(&Stream.terminal?/1)
  end

  test "forced cancellation releases a persisted session from running state" do
    parent = self()
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    assert {:ok, %SessionData{session_id: "cancelled-session"}} =
             Jidoka.Session.start(spec(), "cancelled-session", store: store)

    llm = fn _intent, _journal, _context ->
      send(parent, {:session_capability_started, self()})
      Process.sleep(5_000)
      {:ok, %{type: :final, content: "too late"}}
    end

    assert {:ok, request} =
             Jidoka.Session.chat_async("cancelled-session", "Cancel this",
               store: store,
               llm: llm,
               cancellation_poll_interval_ms: 1_000
             )

    assert_receive {:session_capability_started, capability_pid}, 1_000

    assert {:ok, %Cancellation{forced?: true} = cancellation} =
             Jidoka.Session.cancel(request, grace_ms: 5)

    assert {:cancelled, ^cancellation} = Jidoka.Session.await(request, timeout: 100)
    refute Process.alive?(capability_pid)

    assert {:ok,
            %SessionData{
              status: :cancelled,
              error: %Cancellation{request_id: request_id}
            }} = Jidoka.Session.get(store, "cancelled-session")

    assert request_id == request.request_id
  end

  test "a completed request cannot later change to cancelled" do
    assert {:ok, request} =
             Request.start_fun(
               :completed_target,
               "Complete this",
               [request_id: "req_completed_before_cancel"],
               fn _opts -> {:ok, "done"} end
             )

    assert {:ok, "done"} = Jidoka.await(request, timeout: 100)
    assert {:error, :request_already_finished} = Jidoka.cancel(request)
    assert {:ok, "done"} = Jidoka.await(request, timeout: 100)
  end

  test "a published terminal event wins a race with cancellation" do
    assert {:ok, request} =
             Request.start_fun(
               :terminal_race_target,
               "Complete this",
               [stream: true, request_id: "req_terminal_race"],
               fn opts ->
                 :ok =
                   Stream.emit(
                     Event.build(:turn_finished, [], request_id: "req_terminal_race"),
                     opts
                   )

                 Process.sleep(50)
                 {:ok, "done"}
               end
             )

    assert_receive {:jidoka_turn_event, %Event{event: :turn_finished, request_id: "req_terminal_race"}},
                   1_000

    assert {:error, :request_already_finished} = Jidoka.cancel(request)
    assert {:ok, "done"} = Jidoka.await(request, timeout: 1_000)
  end

  test "await timeout cancels the request but keeps timeout as the caller result" do
    assert {:ok, request} =
             Request.start_fun(
               :timeout_target,
               "Wait",
               [request_id: "req_await_timeout"],
               fn _opts ->
                 Process.sleep(5_000)
                 {:ok, "too late"}
               end
             )

    assert {:error, :timeout} = Jidoka.await(request, timeout: 1, cancel_grace_ms: 5)
    assert {:cancelled, %Cancellation{forced?: true}} = Jidoka.await(request, timeout: 100)
  end

  defp spec do
    Agent.Spec.new!(
      id: "cancellation_agent",
      instructions: "Answer briefly.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp wait_for_cancellation(_context, 0), do: {:error, :cancellation_not_received}

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      :ok
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end
end
