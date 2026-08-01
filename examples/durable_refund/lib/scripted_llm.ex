defmodule JidokaExamples.DurableRefund.ScriptedLLM do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Stream

  def refund_round_trip(order_id \\ "A1001", amount \\ 42.0) do
    fn _intent, %Effect.Journal{} = journal, _context ->
      if result_count(journal, :llm) == 0 do
        {:ok,
         %{
           type: :operation,
           name: "issue_refund",
           arguments: %{"amount" => amount, "order_id" => order_id}
         }}
      else
        refund = operation_output(journal)
        {:ok, %{type: :final, content: "Refund #{refund["refund_id"]} is #{refund["status"]}."}}
      end
    end
  end

  def final(content) when is_binary(content) do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: content}} end
  end

  def streaming(request_id, stream_to) do
    fn %Effect.Intent{} = intent, _journal, _context ->
      sinks = [stream_to: stream_to]

      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :thinking, delta: "check policy "}
          ),
          sinks
        )

      :ok =
        Stream.emit(
          Event.build(:llm_delta, [],
            request_id: request_id,
            effect_id: intent.id,
            effect_kind: :llm,
            data: %{chunk_type: :content, delta: "Refund guidance is ready."}
          ),
          sinks
        )

      {:ok, %{type: :final, content: "Refund guidance is ready."}}
    end
  end

  def cancellable(observer) do
    fn _intent, _journal, context ->
      send(observer, {:cancellable_model_started, self()})
      wait_for_cancellation(context, 1_000)
    end
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

  defp operation_output(%Effect.Journal{} = journal) do
    journal.results
    |> Map.values()
    |> Enum.find(&(&1.kind == :operation))
    |> Map.fetch!(:output)
  end

  defp result_count(%Effect.Journal{} = journal, kind) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == kind end)
  end
end
