defmodule JidokaExamples.DurableRefund.Scenarios.AsyncExecution do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Stream
  alias JidokaExamples.DurableRefund.Agent
  alias JidokaExamples.DurableRefund.ScriptedLLM

  def stream(opts \\ []) do
    request_id = Keyword.get(opts, :request_id, "durable-refund-stream")
    observer = Keyword.get(opts, :observer, self())

    with {:ok, request} <-
           Jidoka.chat_async(Agent, "Stream refund guidance",
             request_id: request_id,
             stream: true,
             llm: ScriptedLLM.streaming(request_id, observer)
           ),
         stream = Jidoka.stream(request, stream_event_timeout_ms: 100),
         {:ok, "Refund guidance is ready." = answer} <- Jidoka.await(request, timeout: 1_000) do
      events = Enum.to_list(stream)

      {:ok,
       %{
         answer: answer,
         events: events,
         request_id: request_id,
         terminal_events: Enum.filter(events, &Stream.terminal?/1),
         text: events |> Enum.map(&Stream.text_delta/1) |> Enum.reject(&is_nil/1) |> Enum.join(),
         thinking: events |> Enum.map(&Stream.thinking_delta/1) |> Enum.reject(&is_nil/1) |> Enum.join()
       }}
    end
  end

  def cancel(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    request_id = Keyword.get(opts, :request_id, "durable-refund-cancel")

    with {:ok, request} <-
           Jidoka.chat_async(Agent, "Cancel this refund check",
             request_id: request_id,
             stream: true,
             llm: ScriptedLLM.cancellable(observer)
           ),
         {:ok, capability_pid} <- await_capability_start(request_id),
         {:ok, %Cancellation{} = cancellation} <- Jidoka.cancel(request, grace_ms: 500),
         {:cancelled, ^cancellation} <- Jidoka.await(request, timeout: 100) do
      events = request |> Jidoka.stream(stream_event_timeout_ms: 100) |> Enum.to_list()

      {:ok,
       %{
         cancellation: cancellation,
         capability_alive?: Process.alive?(capability_pid),
         terminal_events: Enum.filter(events, &Stream.terminal?/1)
       }}
    end
  end

  defp await_capability_start(request_id) do
    receive do
      {:cancellable_model_started, pid} -> {:ok, pid}
    after
      1_000 -> {:error, {:cancellable_model_not_started, request_id}}
    end
  end
end
