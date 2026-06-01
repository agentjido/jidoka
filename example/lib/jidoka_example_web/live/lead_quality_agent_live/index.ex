defmodule JidokaExampleWeb.LeadQualityAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.LeadQualityAgent.Agent
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.LeadQualityAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Is Ada from Northwind a good lead? ada@northwind.example asked about security review and rollout timing."
  @example_root Path.expand("../../../..", __DIR__)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/lead_quality_agent/agent.ex"},
    %{
      id: "enrich",
      label: "Enrich Action",
      path: "lib/jidoka_example/lead_quality_agent/actions/enrich_lead.ex"
    },
    %{
      id: "score",
      label: "Score Action",
      path: "lib/jidoka_example/lead_quality_agent/actions/score_lead.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/lead_quality_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/lead_quality_agent_live/index.ex"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        default_question: @default_question,
        example_root: @example_root,
        guide: Agent.guide(),
        page_title: "Lead Quality Agent",
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
       agent_pid: &lead_quality_agent_pid/0,
       example: "lead_quality_agent"
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       lead_quality_agent_id(),
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
      title="Lead Quality Agent"
      subtitle="Multi-tool qualification"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Lead session"
      panel_subtitle="Enrich, score, decide."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with the sample lead."
      empty_body="The agent should call enrich_lead, then score_lead, then return structured output."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Lead"
      field_placeholder="Ask about a lead..."
      button_label="Qualify"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.lead_result value={AgentLive.result_value(@agent_view)} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr :value, :any, required: true

  defp lead_result(%{value: nil} = assigns), do: ~H""

  defp lead_result(assigns) do
    assigns =
      assign(assigns,
        company: AgentLive.payload_value(assigns.value, :company),
        score: AgentLive.payload_value(assigns.value, :score),
        grade: AgentLive.payload_value(assigns.value, :grade),
        recommendation: AgentLive.payload_value(assigns.value, :recommendation),
        reasons: AgentLive.payload_value(assigns.value, :reasons) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Lead score">
      <div class="kv-grid">
        <div>
          <span>Company</span>
          <strong>{@company}</strong>
        </div>
        <div>
          <span>Score</span>
          <strong>{@score} / 100 ({@grade})</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Recommendation:</strong> {@recommendation}</p>
        <ul>
          <%= for reason <- @reasons do %>
            <li>{reason}</li>
          <% end %>
        </ul>
      </div>
    </section>
    """
  end

  attr :payload, :map, required: true

  defp operation_payload(assigns) do
    output = AgentLive.payload_value(assigns.payload, :output) || %{}

    assigns =
      assign(assigns,
        operation: AgentLive.payload_value(assigns.payload, :operation),
        output: output,
        company: AgentLive.payload_value(output, :company),
        score: AgentLive.payload_value(output, :score),
        grade: AgentLive.payload_value(output, :grade)
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Company</span>
          <strong>{@company || "n/a"}</strong>
        </div>
        <div>
          <span>Score</span>
          <strong>{@score || "n/a"}</strong>
        </div>
        <div>
          <span>Grade</span>
          <strong>{@grade || "n/a"}</strong>
        </div>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp lead_quality_agent_pid,
    do: AgentLive.agent_pid(lead_quality_agent_id(), :lead_quality_agent_not_started)

  defp lead_quality_agent_id, do: Agent.__jidoka_agent_id__()
end
