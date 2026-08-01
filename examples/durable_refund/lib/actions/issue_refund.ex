defmodule JidokaExamples.DurableRefund.Actions.IssueRefund do
  @moduledoc false

  alias Jidoka.Schema

  use Jidoka.Action,
    name: "issue_refund",
    description: "Issues one approved refund with a stable idempotency key.",
    category: "billing",
    tags: ["billing", "refund"],
    schema:
      Zoi.object(%{
        amount: Zoi.number(),
        order_id: Zoi.string()
      })

  @impl true
  def run(params, context) do
    order_id = Schema.get_key(params, :order_id)
    amount = Schema.get_key(params, :amount)
    increment_counter(context)
    notify(context, {:refund_issued, order_id, amount})

    {:ok,
     %{
       "amount" => amount,
       "order_id" => order_id,
       "refund_id" => "refund_#{order_id}",
       "status" => "queued"
     }}
  end

  defp increment_counter(context) do
    case Jidoka.Context.get_runtime(context, :refund_counter) do
      counter when is_pid(counter) -> Elixir.Agent.update(counter, &(&1 + 1))
      _counter -> :ok
    end
  end

  defp notify(context, message) do
    case Jidoka.Context.get_runtime(context, :example_observer) do
      observer when is_pid(observer) -> send(observer, message)
      _observer -> :ok
    end
  end
end
