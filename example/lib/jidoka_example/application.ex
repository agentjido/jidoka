defmodule JidokaExample.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JidokaExample.Jido,
      {JidokaExample.SupportAgent.Agent, jido: JidokaExample.Jido},
      {JidokaExample.ResearchAgent.Agent, jido: JidokaExample.Jido},
      {Phoenix.PubSub, name: JidokaExample.PubSub},
      JidokaExampleWeb.Endpoint
    ]

    opts = [strategy: :rest_for_one, name: JidokaExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    JidokaExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
