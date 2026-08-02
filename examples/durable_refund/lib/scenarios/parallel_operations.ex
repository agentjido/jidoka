defmodule JidokaExamples.DurableRefund.Scenarios.ParallelOperations do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Turn
  alias JidokaExamples.DurableRefund.Agent
  alias JidokaExamples.DurableRefund.ScriptedLLM

  @order_ids ["A1001", "B2002"]

  def run(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())

    task =
      Task.async(fn ->
        Jidoka.turn(Agent, "Check both refund policies",
          llm: ScriptedLLM.parallel_policy_checks(@order_ids),
          max_parallel_operations: 2,
          operation_context: %{example_observer: observer}
        )
      end)

    with {:ok, workers} <- await_workers(@order_ids, %{}),
         :ok <- complete_out_of_order(workers),
         {:ok, %Turn.Result{} = result} <- Task.await(task, 2_000) do
      {:ok,
       %{
         answer: result.content,
         completion_order: completion_order(@order_ids),
         observation_order: Enum.map(result.agent_state.operation_results, & &1.arguments["order_id"]),
         operations: Enum.map(result.agent_state.operation_results, &operation_report/1)
       }}
    end
  end

  defp await_workers([], workers), do: {:ok, workers}

  defp await_workers(pending, workers) do
    receive do
      {:refund_policy_started, order_id, pid} ->
        if order_id in pending do
          await_workers(List.delete(pending, order_id), Map.put(workers, order_id, pid))
        else
          await_workers(pending, workers)
        end
    after
      1_000 -> {:error, {:parallel_policy_checks_not_started, pending}}
    end
  end

  defp complete_out_of_order(workers) do
    Enum.each(Enum.reverse(@order_ids), fn order_id ->
      send(Map.fetch!(workers, order_id), {:release_refund_policy, order_id})

      receive do
        {:refund_policy_completed, ^order_id} -> :ok
      after
        1_000 -> raise "refund policy check did not complete for #{order_id}"
      end
    end)

    :ok
  end

  defp completion_order(order_ids) do
    order_ids
    |> Enum.reverse()
  end

  defp operation_report(%Effect.OperationResult{} = operation) do
    %{
      arguments: operation.arguments,
      operation: operation.operation,
      output: operation.output
    }
  end
end
