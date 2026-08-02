defmodule JidokaExamples.DurableRefund.Actions.CheckRefundPolicy do
  @moduledoc false

  alias Jidoka.Schema

  use Jidoka.Action,
    name: "check_refund_policy",
    description: "Checks refund eligibility without changing an order.",
    category: "billing",
    tags: ["billing", "refund", "read_only"],
    schema:
      Zoi.object(%{
        order_id: Zoi.string()
      })

  @impl true
  def run(params, context) do
    order_id = Schema.get_key(params, :order_id)
    observer = Jidoka.Context.get_runtime(context, :example_observer)

    if is_pid(observer) do
      send(observer, {:refund_policy_started, order_id, self()})

      receive do
        {:release_refund_policy, ^order_id} -> :ok
      after
        1_000 -> raise "refund policy check was not released for #{order_id}"
      end

      send(observer, {:refund_policy_completed, order_id})
    end

    {:ok,
     %{
       "eligible" => true,
       "order_id" => order_id,
       "policy" => "standard_refund"
     }}
  end
end
