defmodule JidokaExamples.SupportAgent.Actions.LookupOrder do
  @moduledoc false

  alias Jidoka.Schema

  @orders %{
    "A1001" => %{
      "status" => "in_transit",
      "carrier" => "UPS",
      "eta" => "the next business day",
      "summary" => "The order left the Chicago regional hub this morning.",
      "recommended_action" => "Tell the customer the package is on schedule and ask them to watch for delivery updates."
    },
    "B2002" => %{
      "status" => "delayed",
      "carrier" => "FedEx",
      "eta" => "within two business days",
      "summary" => "Weather delayed the package at the Denver sort facility.",
      "recommended_action" => "Apologize, explain the weather delay, and offer to monitor the shipment."
    },
    "C3003" => %{
      "status" => "delivered",
      "carrier" => "USPS",
      "eta" => "delivered",
      "summary" => "The package was delivered to the front desk.",
      "recommended_action" => "Ask the customer to check with the front desk or building mailroom."
    }
  }

  use Jidoka.Action,
    name: "lookup_order",
    description: "Looks up shipping status, ETA, and support guidance for an order.",
    category: "support",
    tags: ["support", "order"],
    schema:
      Zoi.object(%{
        order_id: Zoi.string()
      })

  @impl true
  def run(params, context) do
    order_id =
      params
      |> Schema.get_key(:order_id)
      |> to_string()
      |> String.trim()
      |> String.upcase()

    increment_counter(context)
    notify(context, {:lookup_order_called, order_id})

    order =
      Map.get(@orders, order_id, %{
        "status" => "not_found",
        "summary" => "No order matched that id.",
        "recommended_action" => "Ask the customer to confirm the order id."
      })

    {:ok, Map.put(order, "order_id", order_id)}
  end

  defp notify(context, message) do
    case Jidoka.Context.get_runtime(context, :example_observer) do
      observer when is_pid(observer) -> send(observer, message)
      _observer -> :ok
    end
  end

  defp increment_counter(context) do
    case Jidoka.Context.get_runtime(context, :example_counter) do
      counter when is_pid(counter) -> Elixir.Agent.update(counter, &(&1 + 1))
      _counter -> :ok
    end
  end
end
