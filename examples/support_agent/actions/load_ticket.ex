defmodule JidokaExamples.ActionsControls.LoadTicket do
  use Jidoka.Action,
    name: "load_ticket",
    description: "Loads a support ticket from the application database.",
    schema: Zoi.object(%{id: Zoi.string()})

  @impl true
  def run(%{id: id}, context) do
    {:ok,
     %{
       id: id,
       account_id: Map.fetch!(context, :account_id),
       status: :open,
       subject: "Invoice total doubled after plan renewal",
       customer_tier: :enterprise
     }}
  end
end
