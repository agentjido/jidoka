defmodule JidokaExamples.DurableRefund.Scenarios.ExecutionLimits do
  @moduledoc false

  alias Jidoka.Agent.Spec
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Runtime.JidoActions
  alias Jidoka.Schema
  alias JidokaExamples.DurableRefund.Actions.IssueRefund
  alias JidokaExamples.DurableRefund.Agent

  def run(opts \\ []) do
    observer = Keyword.get(opts, :observer, self())
    {:ok, counter} = Elixir.Agent.start_link(fn -> 0 end)
    spec = max_one_turn_spec()

    operation_llm = fn intent, _journal, _context ->
      max_tokens = Schema.get_key(intent.payload.generation.params, :max_tokens)
      send(observer, {:budget_max_tokens, max_tokens})

      {:ok,
       %{
         type: :operation,
         name: "issue_refund",
         arguments: %{"amount" => 42.0, "order_id" => "A1001"}
       }}
    end

    turn_result =
      Jidoka.turn(spec, "Issue the refund",
        llm: operation_llm,
        operations: JidoActions.operations([IssueRefund]),
        operation_context: %{refund_counter: counter}
      )

    slow_llm = fn _intent, _journal, _context ->
      Process.sleep(5_000)
      {:ok, %{type: :final, content: "too late"}}
    end

    timeout_result =
      Jidoka.turn(Agent, "Time out this model",
        llm: slow_llm,
        capability_timeout_ms: 5
      )

    receive do
      {:budget_max_tokens, max_tokens} ->
        {:ok,
         %{
           max_tokens: max_tokens,
           operation_calls: Elixir.Agent.get(counter, & &1),
           timeout_result: timeout_result,
           turn_result: turn_result
         }}
    after
      100 -> {:error, :missing_budget_observation}
    end
  end

  defp max_one_turn_spec do
    %Spec{controls: %Controls{} = current_controls} = spec = Agent.spec()
    controls = %Controls{current_controls | max_turns: 1}
    Spec.new!(%Spec{spec | controls: controls})
  end
end
