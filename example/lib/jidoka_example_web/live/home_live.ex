defmodule JidokaExampleWeb.HomeLive do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Jidoka Examples")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page">
      <header class="page-header">
        <div>
          <p class="eyebrow">Example routes</p>
          <h1>Jidoka agents</h1>
        </div>
      </header>

      <div class="route-list">
        <a class="route-row" href="/agents/support">
          <div>
            <h2>Support Agent</h2>
            <p class="subtle">Customer support</p>
          </div>
          <span class="status idle"><span class="status-dot"></span>Ready</span>
        </a>
      </div>
    </section>
    """
  end
end
