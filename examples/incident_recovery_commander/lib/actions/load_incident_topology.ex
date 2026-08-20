defmodule JidokaExamples.IncidentRecoveryCommander.Actions.LoadIncidentTopology do
  @moduledoc false

  alias Jidoka.Schema
  alias JidokaExamples.IncidentRecoveryCommander.IncidentState

  use Jidoka.Action,
    name: "load_incident_topology",
    description: "Loads the affected service topology without changing external state.",
    schema: Zoi.object(%{incident_id: Zoi.string()})

  @impl true
  def run(params, context) do
    incident_id = Schema.get_key(params, :incident_id)
    increment(context, :topology_loads)

    {:ok,
     %{
       incident_id: incident_id,
       dependencies: %{
         "checkout-api" => ["payments-api"],
         "payments-api" => ["ledger-db"],
         "ledger-db" => []
       },
       services: ["payments-api", "checkout-api", "ledger-db"]
     }}
  end

  defp increment(context, key) do
    case Jidoka.Context.get_runtime(context, :incident_state) do
      pid when is_pid(pid) -> IncidentState.increment(pid, key)
      _state -> :ok
    end
  end
end
