defmodule JidokaExampleWeb.KnowledgeAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.KnowledgeAgent.Agent
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.KnowledgeAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Explain how Jidoka skills and MCP tools fit into the agent loop."
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/knowledge_agent/agent.ex"},
    %{
      id: "skill",
      label: "Skill",
      path: "lib/jidoka_example/knowledge_agent/skills/knowledge_skill.ex"
    },
    %{
      id: "skill_action",
      label: "Skill Action",
      path: "lib/jidoka_example/knowledge_agent/skills/knowledge_topic_lookup.ex"
    },
    %{
      id: "mcp_client",
      label: "MCP Client",
      path: "lib/jidoka_example/knowledge_agent/mcp/local_client.ex"
    },
    %{
      id: "control",
      label: "Output Control",
      path: "lib/jidoka_example/knowledge_agent/controls/require_evidence.ex"
    },
    %{id: "browser", label: "Browser Tools", path: "lib/jidoka/browser.ex", root: :package},
    %{
      id: "mcp_source",
      label: "MCP Source",
      path: "lib/jidoka/operation/source/mcp.ex",
      root: :package
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/knowledge_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/knowledge_agent_live/index.ex"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        default_question: @default_question,
        example_root: @example_root,
        guide: Agent.guide(),
        package_root: @package_root,
        page_title: "Knowledge Agent",
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
       agent_pid: &knowledge_agent_pid/0,
       example: "knowledge_agent",
       operation_context: %{mcp_client: JidokaExample.KnowledgeAgent.MCP.LocalClient}
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       knowledge_agent_id(),
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
      title="Knowledge Agent"
      subtitle="Skills, MCP, and optional web evidence"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Knowledge session"
      panel_subtitle="Ask, gather, cite."
      messages={View.visible_messages(@agent_view)}
      empty_title="Ask about a Jidoka concept."
      empty_body="The agent should use a skill action and MCP note before answering."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Question"
      field_placeholder="Ask about skills, MCP, controls, or Runic..."
      button_label="Ask"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.knowledge_result value={AgentLive.result_value(@agent_view)} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr :value, :any, required: true

  defp knowledge_result(%{value: nil} = assigns), do: ~H""

  defp knowledge_result(assigns) do
    assigns =
      assign(assigns,
        answer: value(assigns.value, :answer),
        evidence: value(assigns.value, :evidence) || [],
        sources: value(assigns.value, :sources) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Knowledge answer">
      <div class="kv-grid">
        <div>
          <span>Structured result</span>
          <strong>Knowledge answer</strong>
        </div>
        <div>
          <span>Evidence</span>
          <strong>{length(@evidence)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Answer:</strong> {@answer}</p>

        <%= if @evidence != [] do %>
          <ul>
            <%= for entry <- @evidence do %>
              <li><strong>{value(entry, :tool)}:</strong> {value(entry, :summary)}</li>
            <% end %>
          </ul>
        <% end %>

        <%= for source <- @sources do %>
          <p>
            <strong>{value(source, :title)}</strong>
            <br />
            <a href={value(source, :url)} target="_blank" rel="noreferrer">
              {value(source, :url)}
            </a>
            <br />
            {value(source, :note)}
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :payload, :map, required: true

  defp operation_payload(assigns) do
    output = AgentLive.payload_value(assigns.payload, :output) || %{}
    result = AgentLive.payload_value(output, :result) || output
    operation = AgentLive.payload_value(assigns.payload, :operation)

    assigns =
      assign(assigns,
        operation: operation,
        source: operation_source(operation),
        summary_items: summary_items(operation, result)
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Source</span>
          <strong>{@source}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= for item <- @summary_items do %>
          <p>{item}</p>
        <% end %>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp knowledge_agent_pid,
    do: AgentLive.agent_pid(knowledge_agent_id(), :knowledge_agent_not_started)

  defp knowledge_agent_id, do: Agent.__jidoka_agent_id__()

  defp summary_items("knowledge_topic_lookup", result) do
    ([compact_line("Topic", value(result, :topic)), value(result, :summary)] ++
       (value(result, :details) || []))
    |> compact()
  end

  defp summary_items("mcp_docs_note", result) do
    result = value(result, :result) || result

    [
      compact_line("Topic", value(result, :topic)),
      value(result, :note),
      value(result, :recommended_use)
    ]
    |> compact()
  end

  defp summary_items("search_web", result) do
    results = value(result, :results) || []

    ([
       compact_line("Query", value(result, :query)),
       compact_line("Results", value(result, :count))
     ] ++
       Enum.map(Enum.take(results, 3), fn search_result ->
         "#{value(search_result, :title)}: #{value(search_result, :url)}"
       end))
    |> compact()
  end

  defp summary_items(operation, result) when operation in ["read_page", "snapshot_url"] do
    [
      compact_line("Title", value(result, :title)),
      compact_line("URL", value(result, :url)),
      result |> value(:content) |> preview()
    ]
    |> compact()
  end

  defp summary_items(_operation, _result), do: ["Operation completed."]

  defp operation_source("knowledge_topic_lookup"), do: "skill"
  defp operation_source("mcp_docs_note"), do: "mcp"

  defp operation_source(operation) when operation in ["search_web", "read_page", "snapshot_url"],
    do: "browser"

  defp operation_source(_operation), do: "operation"

  defp value(map, key), do: AgentLive.payload_value(map, key)

  defp compact_line(_label, nil), do: nil
  defp compact_line(_label, ""), do: nil
  defp compact_line(label, value), do: "#{label}: #{value}"

  defp compact(values), do: Enum.reject(values, &(&1 in [nil, ""]))

  defp preview(nil), do: nil

  defp preview(content) do
    content
    |> to_string()
    |> String.trim()
    |> String.slice(0, 700)
  end
end
