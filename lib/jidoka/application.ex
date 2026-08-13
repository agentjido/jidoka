defmodule Jidoka.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Jidoka.Runtime.EventSequence,
        {Task.Supervisor, name: Jidoka.Chat.TaskSupervisor},
        {DynamicSupervisor, name: Jidoka.Chat.RequestSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Jidoka.Session.Sequence.TaskSupervisor},
        {DynamicSupervisor, name: Jidoka.Session.Sequence.RequestSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Jidoka.Runtime.TaskSupervisor}
      ] ++
        handoff_owner_store_children() ++
        [Jidoka.Jido]

    opts = [strategy: :one_for_one, name: Jidoka.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp handoff_owner_store_children do
    if Jidoka.Handoff.OwnerStore.store() == Jidoka.Handoff.OwnerStore.InMemory do
      [Jidoka.Handoff.OwnerStore.InMemory]
    else
      []
    end
  end
end
