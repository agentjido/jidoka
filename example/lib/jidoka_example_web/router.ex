defmodule JidokaExampleWeb.Router do
  use JidokaExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug JidokaExampleWeb.SessionPlug
    plug :fetch_live_flash
    plug :put_root_layout, html: {JidokaExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", JidokaExampleWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/agents/support", AgentLive.Support, :index
  end
end
