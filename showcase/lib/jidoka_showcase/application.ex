defmodule JidokaShowcase.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    JidokaShowcase.MemoryAgent.Memory.ensure_ready!()

    children = [
      JidokaShowcase.Jido,
      {JidokaExamples.SupportAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.ResearchAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.ApprovalAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.AshAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.LeadQualityAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.MemoryAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.KnowledgeAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.DebugAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.LuaToolsAgent.Agent, jido: JidokaShowcase.Jido},
      {JidokaShowcase.KitchenSinkAgent.Agent, jido: JidokaShowcase.Jido},
      {Phoenix.PubSub, name: JidokaShowcase.PubSub},
      JidokaShowcaseWeb.Endpoint
    ]

    opts = [strategy: :rest_for_one, name: JidokaShowcase.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    JidokaShowcaseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
