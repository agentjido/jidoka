defmodule JidokaExamples.IncidentRecoveryCommander.Actions.IsolateService do
  @moduledoc false

  alias Jidoka.Schema
  alias JidokaExamples.IncidentRecoveryCommander.IncidentState

  use Jidoka.Action,
    name: "isolate_service",
    description: "Isolates one service after an operator approves the change.",
    schema:
      Zoi.object(%{
        change_ticket: Zoi.string(),
        incident_id: Zoi.string(),
        service: Zoi.string()
      })

  @impl true
  def run(params, context) do
    incident_id = Schema.get_key(params, :incident_id)
    service = Schema.get_key(params, :service)
    change_ticket = Schema.get_key(params, :change_ticket)
    increment(context, :service_isolations)

    {:ok,
     %{
       change_ticket: change_ticket,
       incident_id: incident_id,
       service: service,
       status: "isolated"
     }}
  end

  defp increment(context, key) do
    case Jidoka.Context.get_runtime(context, :incident_state) do
      pid when is_pid(pid) -> IncidentState.increment(pid, key)
      _state -> :ok
    end
  end
end
