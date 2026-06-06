defmodule Jidoka.IntegrationSupport.AccountLookupAction do
  @moduledoc false

  use Jidoka.Action,
    name: "account_lookup",
    description: "Looks up account details for multi-turn process-hosted tests.",
    category: "support",
    tags: ["account", "lookup"],
    schema:
      Zoi.object(%{
        account_id: Zoi.string()
      })

  @impl true
  def run(params, context) do
    account_id = Map.get(params, :account_id) || Map.get(params, "account_id")

    if pid = Jidoka.Context.get(context, :test_pid) || Jidoka.Context.get_runtime(context, :test_pid) do
      send(pid, {:account_lookup_called, account_id})
    end

    {:ok, %{account_id: account_id, plan: "Pro", seats: 8}}
  end
end
