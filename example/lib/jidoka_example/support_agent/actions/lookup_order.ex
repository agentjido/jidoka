defmodule JidokaExample.SupportAgent.Actions.LookupOrder do
  @moduledoc false

  use Jidoka.Action,
    name: "lookup_order",
    description: "Looks up shipping status, ETA, and support guidance for an order.",
    schema:
      Zoi.object(%{
        order_id: Zoi.string()
      })

  @impl true
  def run(params, _context) do
    order_id =
      params
      |> Map.get(:order_id, Map.get(params, "order_id", ""))
      |> to_string()
      |> String.trim()
      |> String.upcase()

    with {:ok, orders} <- load_orders() do
      order =
        Map.get(orders, order_id, %{
          "status" => "not_found",
          "summary" => "No order matched that id.",
          "recommended_action" => "Ask the customer to confirm the order id."
        })

      {:ok, Map.put(order, "order_id", order_id)}
    end
  end

  defp load_orders do
    with {:ok, body} <- File.read(orders_path()),
         {:ok, orders} <- Jason.decode(body) do
      {:ok, orders}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_order_data, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:order_data_unavailable, reason}}
    end
  end

  defp orders_path do
    case :code.priv_dir(:jidoka_example) do
      {:error, _reason} -> Path.expand("../../../../priv/support_agent/orders.json", __DIR__)
      path -> Path.join(to_string(path), "support_agent/orders.json")
    end
  end
end
