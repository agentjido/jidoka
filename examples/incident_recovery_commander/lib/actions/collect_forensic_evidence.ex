defmodule JidokaExamples.IncidentRecoveryCommander.Actions.CollectForensicEvidence do
  @moduledoc false

  alias Jidoka.Schema
  alias JidokaExamples.IncidentRecoveryCommander.IncidentState

  use Jidoka.Action,
    name: "collect_forensic_evidence",
    description: "Collects a bounded, read-only forensic evidence set.",
    schema:
      Zoi.object(%{
        incident_id: Zoi.string(),
        service: Zoi.string()
      })

  @impl true
  def run(params, context) do
    incident_id = Schema.get_key(params, :incident_id)
    service = Schema.get_key(params, :service)
    increment(context, :forensic_collections)

    {:ok,
     %{
       incident_id: incident_id,
       service: service,
       finding: "Connection pool exhaustion followed a dependency timeout.",
       confidence: 0.97
     }}
  end

  defp increment(context, key) do
    case Jidoka.Context.get_runtime(context, :incident_state) do
      pid when is_pid(pid) -> IncidentState.increment(pid, key)
      _state -> :ok
    end
  end
end
