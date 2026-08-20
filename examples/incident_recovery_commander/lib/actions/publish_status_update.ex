defmodule JidokaExamples.IncidentRecoveryCommander.Actions.PublishStatusUpdate do
  @moduledoc false

  alias Jidoka.Schema
  alias JidokaExamples.IncidentRecoveryCommander.IncidentState

  use Jidoka.Action,
    name: "publish_status_update",
    description: "Publishes one reviewed incident status update.",
    schema:
      Zoi.object(%{
        incident_id: Zoi.string(),
        message: Zoi.string()
      })

  @impl true
  def run(params, context) do
    incident_id = Schema.get_key(params, :incident_id)
    message = Schema.get_key(params, :message)
    increment(context, :status_updates)

    {:ok,
     %{
       incident_id: incident_id,
       message: message,
       publication_id: "status-#{incident_id}",
       status: "published"
     }}
  end

  defp increment(context, key) do
    case Jidoka.Context.get_runtime(context, :incident_state) do
      pid when is_pid(pid) -> IncidentState.increment(pid, key)
      _state -> :ok
    end
  end
end
