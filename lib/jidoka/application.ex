defmodule Jidoka.Application do
  @moduledoc """
  OTP application entrypoint for the MVP runtime.

  The topology intentionally stays small while preserving clear ownership:
  a registry, session and attempt supervisors, an event bus, and one durable
  session writer process.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- Jidoka.RuntimeBootstrap.prepare_tzdata() do
      children = [
        {Registry, keys: :unique, name: Jidoka.Registry},
        Jidoka.SessionSupervisor,
        Jidoka.AttemptSupervisor,
        Jidoka.Bus,
        Jidoka.SessionServer
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: Jidoka.Supervisor)
    end
  end
end
