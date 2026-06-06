defmodule JidokaExample.LuaToolsAgent.Actions.ListUnpaidInvoices do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_demo_list_unpaid_invoices",
    description: "Lists unpaid demo invoices for one customer.",
    schema:
      Zoi.object(%{
        customer_id: Zoi.string() |> Zoi.default(""),
        value: Zoi.string() |> Zoi.nullish(),
        limit: Zoi.integer() |> Zoi.default(5)
      })

  @impl true
  def run(params, context) do
    customer_id = params |> customer_id() |> to_string()
    limit = params |> get(:limit, 5) |> clamp_limit()

    maybe_wait_for_parallel_test(customer_id, context)

    with :ok <- maybe_fail_for_retry_test(customer_id, context) do
      invoices =
        invoices()
        |> Map.get(customer_id, [])
        |> Enum.take(limit)

      {:ok,
       %{
         "customer_id" => customer_id,
         "invoices" => invoices,
         "count" => length(invoices),
         "total_due_cents" => Enum.reduce(invoices, 0, &(&1["amount_cents"] + &2))
       }}
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(10)

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} -> clamp_limit(parsed)
      :error -> 5
    end
  end

  defp clamp_limit(_limit), do: 5

  defp get(params, key, default) do
    Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  defp customer_id(params) do
    case get(params, :customer_id, "") do
      "" -> get(params, :value, "")
      customer_id -> customer_id
    end
  end

  defp maybe_wait_for_parallel_test(customer_id, context) do
    case Jidoka.Context.get(context, :lua_test_pid) do
      pid when is_pid(pid) ->
        send(
          pid,
          {:lua_hidden_action_started, "billing.invoice.list_unpaid", customer_id, self()}
        )

        receive do
          :continue_lua_hidden_action -> :ok
        after
          1_000 -> :ok
        end

      _other ->
        :ok
    end
  end

  defp maybe_fail_for_retry_test(customer_id, context) do
    case Jidoka.Context.get(context, :lua_retry_test_pid) do
      pid when is_pid(pid) ->
        send(pid, {:lua_retry_invoice_attempt, customer_id, self()})

        receive do
          :fail_lua_invoice_attempt -> {:error, %{"reason" => "forced retry test failure"}}
          :continue_lua_invoice_attempt -> :ok
        after
          1_000 -> :ok
        end

      _other ->
        :ok
    end
  end

  defp invoices do
    %{
      "cus_ada" => [
        %{
          "id" => "inv_1001",
          "amount_cents" => 42_500,
          "due_date" => "2026-05-20",
          "status" => "overdue"
        },
        %{
          "id" => "inv_1002",
          "amount_cents" => 18_000,
          "due_date" => "2026-06-15",
          "status" => "open"
        }
      ],
      "cus_grace" => [
        %{
          "id" => "inv_2001",
          "amount_cents" => 132_000,
          "due_date" => "2026-05-01",
          "status" => "overdue"
        }
      ],
      "cus_alan" => []
    }
  end
end
