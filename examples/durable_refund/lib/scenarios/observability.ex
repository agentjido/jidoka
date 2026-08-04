defmodule JidokaExamples.DurableRefund.Scenarios.Observability do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Event
  alias Jidoka.Trace
  alias Jidoka.Trace.Policy
  alias Jidoka.Trace.Sink.InMemory
  alias JidokaExamples.DurableRefund.Agent

  def run do
    with {:ok, result} <- Jidoka.turn(Agent, "Check whether order A1001 can be refunded.", llm: model()),
         {:ok, sink} <- InMemory.start_link(),
         :ok <- record_trace(result, sink) do
      {:ok,
       %{
         result: result,
         trace: InMemory.list(sink),
         usage: Jidoka.project(result.usage)
       }}
    end
  end

  defp model do
    fn _intent, %Effect.Journal{} = journal, _context ->
      case result_count(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "check_refund_policy",
             arguments: %{"order_id" => "A1001"},
             metadata: %{
               finish_reason: :tool_calls,
               model: "test:durable-refund",
               usage: %{input_tokens: 12, output_tokens: 4, total_cost: 0.001}
             }
           }}

        1 ->
          {:ok,
           %{
             type: :final,
             content: "Order A1001 is eligible for the standard refund.",
             metadata: %{
               finish_reason: :stop,
               model: "test:durable-refund",
               usage: %{input_tokens: 18, output_tokens: 7, total_cost: 0.002}
             }
           }}
      end
    end
  end

  defp record_trace(result, sink) do
    sensitive_event =
      Event.build(:prompt_assembled, [],
        request_id: result.metadata.debug.request_id,
        data: %{
          api_key: "example-secret-key",
          prompt: "raw prompt omitted before export",
          visible: %{operation: "check_refund_policy", token: "example-token"}
        }
      )

    Trace.record(result.events ++ [sensitive_event], {InMemory, pid: sink}, policy: Policy.new!())
  end

  defp result_count(%Effect.Journal{} = journal, kind) do
    Enum.count(journal.results, fn {_id, result} -> result.kind == kind end)
  end
end
