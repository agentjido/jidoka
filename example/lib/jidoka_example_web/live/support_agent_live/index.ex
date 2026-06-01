defmodule JidokaExampleWeb.SupportAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.SupportAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Can you check order A1001 and tell me what I should do next?"
  @example_root Path.expand("../../../..", __DIR__)
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
      path: "lib/jidoka_example/support_agent/agent.ex"
    },
    %{
      id: "action",
      label: "Action",
      path: "lib/jidoka_example/support_agent/actions/lookup_order.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/support_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/support_agent_live/index.ex"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        default_question: @default_question,
        example_root: @example_root,
        guide: agent_guide(),
        page_title: "Support Agent",
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
       agent_pid: &support_agent_pid/0,
       example: "support_agent"
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       support_agent_id(),
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
      title="Support Agent"
      subtitle="Customer support"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Support session"
      panel_subtitle="Ask, answer, inspect."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with the sample order."
      empty_body="The first response should call the lookup tool and explain the next step."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Message"
      field_placeholder="Ask about order A1001..."
      button_label="Send"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr(:payload, :map, required: true)

  defp operation_payload(assigns) do
    assigns =
      assign(assigns,
        operation: AgentLive.payload_value(assigns.payload, :operation),
        status: AgentLive.payload_value(assigns.payload, [:output, :status]) || "ok",
        order:
          AgentLive.payload_value(assigns.payload, [:output, :order_id]) ||
            AgentLive.payload_value(assigns.payload, [:arguments, :order_id]),
        eta: AgentLive.payload_value(assigns.payload, [:output, :eta]) || "n/a",
        summary: AgentLive.payload_value(assigns.payload, [:output, :summary]),
        recommended_action:
          AgentLive.payload_value(assigns.payload, [:output, :recommended_action])
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Status</span>
          <strong>{@status}</strong>
        </div>
        <div>
          <span>Order</span>
          <strong>{@order}</strong>
        </div>
        <div>
          <span>ETA</span>
          <strong>{@eta}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p>{@summary}</p>
        <p>{@recommended_action}</p>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp agent_guide, do: JidokaExample.SupportAgent.Agent.guide()

  defp pretty(value), do: AgentLive.pretty(value)

  defp support_agent_pid do
    AgentLive.agent_pid(support_agent_id(), :support_agent_not_started)
  end

  defp support_agent_id, do: JidokaExample.SupportAgent.Agent.spec().id
end
