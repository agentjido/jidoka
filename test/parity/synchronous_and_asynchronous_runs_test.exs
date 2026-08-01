defmodule Jidoka.Parity.SynchronousAndAsynchronousRunsTest do
  use Jidoka.ParityCase, parity: :synchronous_and_asynchronous_runs

  alias Jidoka.Agent
  alias Jidoka.Cancellation
  alias Jidoka.Chat.Request

  test "the same agent contract runs synchronously and through an async request handle" do
    llm = fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "The execution contract is complete."}}
    end

    assert {:ok, "The execution contract is complete."} =
             Jidoka.chat(spec(), "Run synchronously", llm: llm)

    assert {:ok,
            %Request{
              request_id: "parity-e01-async",
              task: %Task{},
              controller: controller,
              cancellation: cancellation
            } = request} =
             Jidoka.chat_async(spec(), "Run asynchronously",
               llm: llm,
               request_id: "parity-e01-async"
             )

    assert is_pid(controller)
    assert is_struct(cancellation, Cancellation.Token)

    assert {:ok, "The execution contract is complete."} =
             Jidoka.await(request, timeout: 1_000)

    assert {:error, :request_already_finished} = Jidoka.cancel(request)
  end

  test "an await timeout cleans up the request without hiding the timeout" do
    assert {:ok, request} =
             Request.start_fun(
               :parity_e01_timeout,
               "Wait",
               [request_id: "parity-e01-timeout"],
               fn _opts ->
                 Process.sleep(5_000)
                 {:ok, "too late"}
               end
             )

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

    refute Process.alive?(request.task.pid)
  end

  defp spec do
    Agent.Spec.new!(
      id: "parity_synchronous_async_agent",
      instructions: "Return the deterministic execution result.",
      model: %{provider: :test, id: "scripted-model"}
    )
  end
end
