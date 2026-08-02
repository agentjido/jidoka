defmodule JidokaExamples.DurableRefund.Scenarios.ProcessHost do
  @moduledoc false

  alias Jidoka.Turn
  alias JidokaExamples.DurableRefund.Agent

  def run do
    id = "durable_refund_host_#{System.unique_integer([:positive])}"

    with {:ok, pid} <- Agent.start(id: id) do
      try do
        with ^pid <- Jidoka.whereis(id),
             {:ok, %Turn.Result{} = result} <-
               Jidoka.turn(pid, "Report the hosted refund-agent status.", llm: final_model()),
             {:ok, terminal} <- Jidoka.await_agent(pid, timeout: 100) do
          {:ok, %{id: id, pid: pid, result: result, terminal: terminal}}
        end
      after
        stop_and_wait(pid)
      end
    end
  end

  defp final_model do
    fn _intent, _journal, _context ->
      {:ok, %{type: :final, content: "The supervised refund agent is ready."}}
    end
  end

  defp stop_and_wait(pid) do
    monitor = Process.monitor(pid)
    :ok = Jidoka.stop_agent(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      1_000 -> raise "process-hosted example agent did not stop"
    end
  end
end
