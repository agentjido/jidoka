defmodule Jidoka.Parity.SynchronousAndAsynchronousRunsTest do
  use Jidoka.ParityCase, parity: :synchronous_and_asynchronous_runs

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Chat.Async, as: AsyncChat
  alias Jidoka.Chat.Request

  @moduletag :e01

  test "the same agent contract runs synchronously and through an async request handle" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "The execution contract is complete."}}
    end

    assert {:ok, "The execution contract is complete."} =
             Jidoka.chat(spec(), "Run synchronously", llm: llm)

    assert {:ok,
            %Request{
              request_id: "parity-e01-async",
              controller: controller
            } = request} =
             Jidoka.chat_async(spec(), "Run asynchronously",
               llm: llm,
               request_id: "parity-e01-async"
             )

    assert is_pid(controller)

    assert {:ok, "The execution contract is complete."} =
             Jidoka.await(request, timeout: 1_000)

    assert {:error, :request_already_finished} = Jidoka.cancel(request)
  end

  test "an await timeout cleans up the request without hiding the timeout" do
    parent = self()

    assert {:ok, request} =
             AsyncChat.start_fun(
               :parity_e01_timeout,
               "Wait",
               [request_id: "parity-e01-timeout"],
               fn _opts ->
                 send(parent, {:async_worker, self()})
                 Process.sleep(5_000)
                 {:ok, "too late"}
               end
             )

    assert_receive {:async_worker, worker}, 1_000
    monitor = Process.monitor(worker)

    assert {:error, :timeout} =
             Jidoka.await(request,
               timeout: 1,
               cancel_grace_ms: 5
             )

    assert {:cancelled,
            %Cancellation{
              request_id: "parity-e01-timeout",
              forced?: true
            }} = Jidoka.await(request, timeout: 100)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
  end

  defp spec do
    Agent.Spec.new!(
      id: "parity_synchronous_async_agent",
      instructions: "Return the deterministic execution result.",
      model: %{provider: :test, id: "scripted-model"}
    )
  end
end
