defmodule JidokaExampleWeb.Router do
  use JidokaExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JidokaExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", JidokaExampleWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/agents/support", SupportAgentLive.Index, :index
    live "/agents/research", ResearchAgentLive.Index, :index
    live "/agents/approval", ApprovalAgentLive.Index, :index
    live "/agents/ash", AshAgentLive.Index, :index
    live "/agents/lead-quality", LeadQualityAgentLive.Index, :index
    live "/agents/memory", MemoryAgentLive.Index, :index
    live "/agents/knowledge", KnowledgeAgentLive.Index, :index
    live "/agents/debug", DebugAgentLive.Index, :index
    live "/agents/lua-tools", LuaToolsAgentLive.Index, :index
    live "/agents/kitchen-sink", KitchenSinkAgentLive.Index, :index
  end
end
