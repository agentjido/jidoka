defmodule Jidoka.Parity.TypedRequestCancellationTest do
  use Jidoka.ParityCase, parity: :typed_request_cancellation

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Event
  alias Jidoka.Stream

  @moduletag :e05

  test "cancellation propagates through active work and owns one terminal result" do
    test_pid = self()

    llm = fn _intent, _journal, context ->
      send(test_pid, {:cancellation_capability_started, self()})
      wait_for_cancellation(context, 1_000)
    end

    assert {:ok, request} =
             Jidoka.chat_async(spec(), "Cancel this request",
               llm: llm,
               request_id: "parity-e05-cancel",
               stream: true
             )

    stream = Jidoka.stream(request, stream_event_timeout_ms: 100)
    assert_receive {:cancellation_capability_started, capability_pid}, 1_000

    assert {:ok,
            %Cancellation{
              request_id: "parity-e05-cancel",
              forced?: false,
              reason: :cancelled
            } = cancellation} = Jidoka.cancel(request, grace_ms: 500)

    assert {:cancelled, ^cancellation} = Jidoka.await(request, timeout: 100)
    refute Process.alive?(capability_pid)
    assert {:error, :request_already_finished} = Jidoka.cancel(request)

    events = Enum.to_list(stream)

    assert [%Event{event: :turn_failed} = terminal] =
             Enum.filter(events, &Stream.terminal?/1)

    assert Event.cancelled?(terminal)
    refute Enum.any?(events, &match?(%Event{event: :turn_finished}, &1))
  end

  defp spec do
    Agent.Spec.new!(
      id: "typed_request_cancellation_agent",
      instructions: "Wait until the request is cancelled.",
      model: %{provider: :test, id: "cancellable"}
    )
  end

  defp wait_for_cancellation(_context, 0), do: {:error, :cancellation_not_received}

  defp wait_for_cancellation(context, attempts_left) do
    if Cancellation.requested?(context) do
      {:error, :cancelled}
    else
      Process.sleep(1)
      wait_for_cancellation(context, attempts_left - 1)
    end
  end
end
