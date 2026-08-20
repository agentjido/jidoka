defmodule JidokaExamples.IncidentRecoveryCommander.Workflows.Functions do
  @moduledoc false

  alias Jidoka.Schema

  @service_risk %{
    "payments-api" => 100,
    "checkout-api" => 80,
    "ledger-db" => 60
  }

  def validate(%{incident_id: incident_id, services: services}, _context) do
    {:ok, %{incident_id: incident_id, services: Enum.uniq(services)}}
  end

  def assess_service(%{index: index, service: service}, _context) do
    {:ok,
     %{
       index: index,
       risk: Map.get(@service_risk, service, 10),
       service: service
     }}
  end

  def rank_services(%{assessments: assessments, incident_id: incident_id}, _context) do
    services =
      assessments
      |> Enum.sort_by(&{-Schema.get_key(&1, :risk), Schema.get_key(&1, :index)})
      |> Enum.map(&Schema.get_key(&1, :service))

    {:ok, %{incident_id: incident_id, services: services}}
  end

  def reserve_capacity(%{incident_id: incident_id, services: services}, _context) do
    counter_key = {__MODULE__, :capacity_reservation, incident_id}
    attempt = Process.get(counter_key, 0) + 1
    Process.put(counter_key, attempt)

    if attempt == 1 do
      {:error, :recovery_capacity_busy}
    else
      {:ok,
       %{
         capacity_reservation_id: "capacity-#{incident_id}",
         incident_id: incident_id,
         reservation_attempts: attempt,
         services: services
       }}
    end
  end

  def restart_next(%{state: %{pending: []} = state}, _context), do: {:halt, state}

  def restart_next(%{state: state}, context) do
    [service | pending] = state.pending

    next = %{
      state
      | checkpointed: true,
        pending: pending,
        restored: state.restored ++ [service]
    }

    created_work = [%{service: service, ticket: "restart-#{service}"}]

    if Jidoka.Context.get(context, :pause_recovery, false) and not state.checkpointed do
      {:suspend, next, created_work}
    else
      {:cont, next, created_work}
    end
  end

  def finalize(%{reservation: reservation, recovery: recovery}, _context) do
    {:ok,
     %{
       capacity_reservation_id: reservation.capacity_reservation_id,
       created_work: recovery.created_work,
       incident_id: reservation.incident_id,
       reservation_attempts: reservation.reservation_attempts,
       restored_services: recovery.value.restored
     }}
  end
end
