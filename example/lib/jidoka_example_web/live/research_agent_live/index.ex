defmodule JidokaExampleWeb.ResearchAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.ResearchAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "What are the most important things to know about Runic workflows in Elixir?"
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{
      id: "jido",
      label: "Jido",
      path: "lib/jidoka_example/jido.ex"
    },
    %{
      id: "application",
      label: "Application",
      path: "lib/jidoka_example/application.ex"
    },
    %{
      id: "agent",
      label: "Agent",
      path: "lib/jidoka_example/research_agent/agent.ex"
    },
    %{
      id: "control",
      label: "Output Control",
      path: "lib/jidoka_example/research_agent/controls/require_sources.ex"
    },
    %{
      id: "search_tool",
      label: "Search Tool",
      path: "lib/jidoka/browser/tools/search_web.ex",
      root: :package
    },
    %{
      id: "read_page_tool",
      label: "Read Page",
      path: "lib/jidoka/browser/tools/read_page.ex",
      root: :package
    },
    %{
      id: "snapshot_tool",
      label: "Snapshot",
      path: "lib/jidoka/browser/tools/snapshot_url.ex",
      root: :package
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/research_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/research_agent_live/index.ex"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        credentials: :research,
        default_question: @default_question,
        example_root: @example_root,
        guide: agent_guide(),
        package_root: @package_root,
        page_title: "Research Agent",
        sources: @sources,
        tabs: @tabs
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, AgentLive.apply_route(socket, params, @tabs, @sources)}
  end

  @impl true
  def handle_event("send_message", %{"prompt" => params}, socket) do
    {:noreply,
     AgentLive.run_prompt(socket, params, View,
       agent_pid: &research_agent_pid/0,
       example: "research_agent",
       missing_error: "Set an LLM key and BRAVE_SEARCH_API_KEY to run research."
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       research_agent_id(),
       @default_question
     )}
  end

  def handle_event("show_tab", %{"tab" => tab}, socket) do
    {:noreply, AgentLive.show_tab(socket, tab, @tabs)}
  end

  def handle_event("show_source", %{"source" => source}, socket) do
    {:noreply, AgentLive.show_source(socket, source, @sources)}
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({@stream_message_tag, %Jidoka.Event{} = event}, socket) do
    {:noreply, AgentLive.apply_stream_event(socket, View, event)}
  end

  def handle_info({:jidoka_turn_result, request_id, result, model}, socket) do
    {:noreply, AgentLive.finish_turn(socket, View, request_id, result, model)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_page
      title="Research Agent"
      subtitle="Web research"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Research session"
      panel_subtitle="Search, summarize, inspect."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with a focused question."
      empty_body="The first response should call web search and summarize sourced results."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Question"
      field_placeholder="Ask a research question..."
      button_label="Search"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.research_brief value={AgentLive.result_value(@agent_view)} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr(:value, :any, required: true)

  defp research_brief(%{value: nil} = assigns), do: ~H""

  defp research_brief(assigns) do
    sources = AgentLive.payload_value(assigns.value, :sources) || []

    assigns =
      assign(assigns,
        summary: AgentLive.payload_value(assigns.value, :summary),
        key_points: AgentLive.payload_value(assigns.value, :key_points) || [],
        sources: sources
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Research brief">
      <div class="kv-grid">
        <div>
          <span>Structured result</span>
          <strong>Research brief</strong>
        </div>
        <div>
          <span>Sources</span>
          <strong>{length(@sources)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Summary:</strong> {@summary}</p>

        <%= if @key_points != [] do %>
          <ul>
            <%= for point <- @key_points do %>
              <li>{point}</li>
            <% end %>
          </ul>
        <% end %>

        <%= for source <- @sources do %>
          <p>
            <strong>{result_value(source, :title)}</strong>
            <br />
            <a href={result_value(source, :url)} target="_blank" rel="noreferrer">
              {result_value(source, :url)}
            </a>
            <br />
            {result_value(source, :note)}
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr(:payload, :map, required: true)

  defp operation_payload(assigns) do
    operation = AgentLive.payload_value(assigns.payload, :operation)

    assigns =
      assign(assigns,
        operation: operation,
        page_result?: operation in ["read_page", "snapshot_url"],
        query:
          AgentLive.payload_value(assigns.payload, [:output, :query]) ||
            AgentLive.payload_value(assigns.payload, [:arguments, :query]),
        url:
          AgentLive.payload_value(assigns.payload, [:output, :url]) ||
            AgentLive.payload_value(assigns.payload, [:arguments, :url]),
        title: AgentLive.payload_value(assigns.payload, [:output, :title]),
        content_preview:
          assigns.payload
          |> AgentLive.payload_value([:output, :content])
          |> content_preview(),
        count: AgentLive.payload_value(assigns.payload, [:output, :count]) || 0,
        results: AgentLive.payload_value(assigns.payload, [:output, :results]) || []
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>{if @page_result?, do: "Page", else: "Results"}</span>
          <strong>{if @page_result?, do: @title || "read", else: @count}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= if @page_result? do %>
          <p><strong>URL:</strong> <a href={@url} target="_blank" rel="noreferrer">{@url}</a></p>
          <p>{@content_preview}</p>
        <% else %>
          <p><strong>Query:</strong> {@query}</p>

          <%= if @results == [] do %>
            <p>No search results returned.</p>
          <% else %>
            <%= for result <- Enum.take(@results, 5) do %>
              <p>
                <strong>{result_value(result, :rank)}. {result_value(result, :title)}</strong>
                <br />
                <a href={result_value(result, :url)} target="_blank" rel="noreferrer">
                  {result_value(result, :url)}
                </a>
                <br />
                {result_value(result, :snippet)}
              </p>
            <% end %>
          <% end %>
        <% end %>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp agent_guide, do: JidokaExample.ResearchAgent.Agent.guide()

  defp pretty(value), do: AgentLive.pretty(value)

  defp research_agent_pid do
    AgentLive.agent_pid(research_agent_id(), :research_agent_not_started)
  end

  defp research_agent_id, do: JidokaExample.ResearchAgent.Agent.__jidoka_agent_id__()

  defp result_value(result, key), do: AgentLive.payload_value(result, key)

  defp content_preview(nil), do: "No page content returned."

  defp content_preview(content) do
    content
    |> to_string()
    |> String.trim()
    |> String.slice(0, 900)
  end
end
