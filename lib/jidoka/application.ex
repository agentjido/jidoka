defmodule Jidoka.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Jidoka.Config

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
        jido_children()

    opts = [strategy: :one_for_one, name: Jidoka.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp jido_children do
    if Config.start_jido?(), do: [Config.jido_runtime()], else: []
  end

  defp handoff_owner_store_children do
    if Jidoka.Handoff.OwnerStore.store() == Jidoka.Handoff.OwnerStore.InMemory do
      [Jidoka.Handoff.OwnerStore.InMemory]
    else
      []
    end
  end
end
