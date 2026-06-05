defmodule JidokaExample.LuaToolsAgent.Actions.DraftFollowupNote do
  @moduledoc false

  use Jidoka.Action,
    name: "lua_demo_draft_followup_note",
    description:
      "Drafts a short customer follow-up note for unpaid invoices. Required args: customer_name, company, invoice_count, total_due_cents.",
    schema:
      Zoi.object(%{
        customer_name: Zoi.string(),
        company: Zoi.string(),
        invoice_count: Zoi.integer(),
        total_due_cents: Zoi.integer()
      })

  @impl true
  def run(params, _context) do
    invoice_count = params |> get(:invoice_count, 0) |> to_integer()
    total_due_cents = params |> get(:total_due_cents, 0) |> to_integer()
    total_due = :erlang.float_to_binary(total_due_cents / 100, decimals: 2)

    {:ok,
     %{
       "customer_name" => get(params, :customer_name, "there"),
       "company" => get(params, :company, "your company"),
       "invoice_count" => invoice_count,
       "total_due_cents" => total_due_cents,
       "note" =>
         "Hi #{get(params, :customer_name, "there")}, I noticed #{invoice_count} open invoice(s) for #{get(params, :company, "your account")} totaling $#{total_due}. Can we help reconcile these this week?"
     }}
  end

  defp get(params, key, default) do
    Map.get(params, key, Map.get(params, Atom.to_string(key), default))
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: round(value)

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> 0
    end
  end

  defp to_integer(_value), do: 0
end
