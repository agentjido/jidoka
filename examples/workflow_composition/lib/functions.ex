defmodule JidokaExamples.WorkflowComposition.Functions do
  @moduledoc false

  alias Jidoka.Schema

  def validate(%{items: items}, _context) do
    {:ok, %{items: items, item_count: length(items)}}
  end

  def priority_route(_input, _context), do: {:ok, %{route: :priority}}
  def standard_route(_input, _context), do: {:ok, %{route: :standard}}

  def enrich_item(%{index: index, item: item}, _context) do
    quantity = Schema.get_key(item, :quantity)
    unit_price = Schema.get_key(item, :unit_price)

    {:ok,
     %{
       index: index,
       quantity: quantity,
       sku: Schema.get_key(item, :sku),
       subtotal: quantity * unit_price
     }}
  end

  def summarize(%{items: items, route: route}, _context) do
    {:ok,
     %{
       items: items,
       route: Schema.get_key(route, :route),
       total: Enum.sum(Enum.map(items, &Schema.get_key(&1, :subtotal)))
     }}
  end

  def reserve_inventory(summary, context) do
    attempt = next_attempt(context)
    notify(context, {:inventory_reservation_attempt, attempt})

    if attempt == 1 do
      {:error, :inventory_service_busy}
    else
      {:ok, Map.put(summary, :reservation_attempts, attempt)}
    end
  end

  def ship_next(%{state: %{pending: []} = state}, _context), do: {:halt, state}

  def ship_next(%{state: state}, _context) do
    [item | pending] = state.pending
    sku = Schema.get_key(item, :sku)

    created_work =
      if sku == "starter_kit" and not state.bonus_created do
        [%{index: 99, quantity: 1, sku: "welcome_card", subtotal: 0}]
      else
        []
      end

    next = %{
      bonus_created: state.bonus_created or created_work != [],
      pending: pending ++ created_work,
      shipped: state.shipped ++ [sku]
    }

    {:cont, next, created_work}
  end

  def finalize(%{reservation: reservation, route: route, shipment: shipment}, _context) do
    {:ok,
     %{
       created_work: shipment.created_work,
       reservation_attempts: reservation.reservation_attempts,
       route: route.route,
       shipped: shipment.value.shipped,
       total: reservation.total
     }}
  end

  defp next_attempt(context) do
    case Jidoka.Context.get_runtime(context, :retry_counter) do
      pid when is_pid(pid) -> Elixir.Agent.get_and_update(pid, &{&1 + 1, &1 + 1})
      _counter -> 2
    end
  end

  defp notify(context, message) do
    case Jidoka.Context.get_runtime(context, :observer) do
      pid when is_pid(pid) -> send(pid, message)
      _observer -> :ok
    end
  end
end
