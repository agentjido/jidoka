defmodule JidokaExampleWeb.HomeLive do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  @agent_examples [
    %{
      id: :support,
      title: "Support Agent",
      description: "One action and basic controls",
      path: "/agents/support",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :research,
      title: "Research Agent",
      description: "Browser search and page reads",
      path: "/agents/research",
      status: "Ready",
      status_class: "idle"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, agent_examples: @agent_examples, page_title: "Jidoka Examples")}
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
        <%= for example <- @agent_examples do %>
          <a class="route-row" href={example.path}>
            <div>
              <h2>{example.title}</h2>
              <p class="subtle">{example.description}</p>
            </div>
            <span class={"status #{example.status_class}"}>
              <span class="status-dot"></span>{example.status}
            </span>
          </a>
        <% end %>
      </div>
    </section>
    """
  end
end
