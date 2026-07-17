defmodule Jidoka.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: Jidoka.Chat.TaskSupervisor},
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
