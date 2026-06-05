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
      description: "Browser research and sourced briefs",
      path: "/agents/research",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :approval,
      title: "Approval Flow Agent",
      description: "Human review before side effects",
      path: "/agents/approval",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :ash,
      title: "Ash Agent",
      description: "Ash resources exposed as tools",
      path: "/agents/ash",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :lead_quality,
      title: "Lead Quality Agent",
      description: "Multi-tool scoring with structured output",
      path: "/agents/lead-quality",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :memory,
      title: "Memory Agent",
      description: "Session memory backed by jido_memory",
      path: "/agents/memory",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :knowledge,
      title: "Knowledge Agent",
      description: "Skills, MCP, and optional web evidence",
      path: "/agents/knowledge",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :debug,
      title: "Debug Agent",
      description: "Inspect and preflight agent definitions",
      path: "/agents/debug",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :lua_tools,
      title: "Lua Tools Agent",
      description: "Dynamic scripting over hidden host tools",
      path: "/agents/lua-tools",
      status: "Ready",
      status_class: "idle"
    },
    %{
      id: :kitchen_sink,
      title: "Kitchen Sink Agent",
      description: "Every stable V2 feature in one route",
      path: "/agents/kitchen-sink",
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
