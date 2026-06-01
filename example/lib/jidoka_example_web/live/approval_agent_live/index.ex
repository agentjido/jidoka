defmodule JidokaExampleWeb.ApprovalAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.ApprovalAgent.Agent
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.ApprovalAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Please refund order B2002 for $25 because the shipment is delayed."
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
      path: "lib/jidoka_example/approval_agent/agent.ex"
    },
    %{
      id: "action",
      label: "Action",
      path: "lib/jidoka_example/approval_agent/actions/issue_refund.ex"
    },
    %{
      id: "control",
      label: "Control",
      path: "lib/jidoka_example/approval_agent/controls/require_refund_approval.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/approval_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/approval_agent_live/index.ex"
    },
    %{
      id: "review",
      label: "Review Runtime",
      path: "lib/jidoka/review.ex",
      root: :package
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        default_question: @default_question,
        example_root: @example_root,
        guide: agent_guide(),
        package_root: @package_root,
        page_title: "Approval Flow Agent",
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
       agent_pid: &approval_agent_pid/0,
       example: "approval_agent"
     )}
  end

  def handle_event("review", %{"decision" => decision}, socket)
      when decision in ["approved", "denied"] do
    {:noreply,
     AgentLive.resume_review(socket, View, Agent, review_decision(decision),
       model: socket.assigns.form[:model].value
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       approval_agent_id(),
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
      title="Approval Flow Agent"
      subtitle="Human review"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Approval session"
      panel_subtitle="Request, review, resume."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with a refund request."
      empty_body="The first turn should pause before the refund action runs."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Request"
      field_placeholder="Ask for a refund..."
      button_label="Request refund"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.pending_review agent_view={@agent_view} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr(:agent_view, :map, required: true)

  defp pending_review(assigns) do
    assigns =
      case AgentLive.pending_review(assigns.agent_view) do
        {:ok, _snapshot, review} -> assign(assigns, review: review)
        {:error, _reason} -> assign(assigns, review: nil)
      end

    ~H"""
    <%= if @review do %>
      <section class="approval-card" aria-label="Pending approval">
        <div>
          <h3>Pending review</h3>
          <p>{@review.operation} is waiting for approval before the operation runs.</p>
        </div>

        <div class="kv-grid">
          <div>
            <span>Operation</span>
            <strong>{@review.operation}</strong>
          </div>
          <div>
            <span>Reason</span>
            <strong>{@review.reason}</strong>
          </div>
        </div>

        <pre><%= AgentLive.pretty(@review.arguments) %></pre>

        <div class="button-row">
          <button
            class="button secondary"
            type="button"
            phx-click="review"
            phx-value-decision="denied"
          >
            Reject
          </button>
          <button class="button" type="button" phx-click="review" phx-value-decision="approved">
            Approve
          </button>
        </div>
      </section>
    <% end %>
    """
  end

  attr(:payload, :map, required: true)

  defp operation_payload(assigns) do
    output = AgentLive.payload_value(assigns.payload, :output) || %{}

    assigns =
      assign(assigns,
        operation: AgentLive.payload_value(assigns.payload, :operation),
        approval_id: AgentLive.payload_value(output, :approval_id),
        status: AgentLive.payload_value(output, :status),
        order_id: AgentLive.payload_value(output, :order_id),
        amount: AgentLive.payload_value(output, :amount),
        reason: AgentLive.payload_value(output, :reason)
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
          <strong>{@order_id}</strong>
        </div>
        <div>
          <span>Amount</span>
          <strong>{@amount}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Approval:</strong> {@approval_id}</p>
        <p>{@reason}</p>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp agent_guide, do: Agent.guide()

  defp approval_agent_pid do
    AgentLive.agent_pid(approval_agent_id(), :approval_agent_not_started)
  end

  defp approval_agent_id, do: Agent.__jidoka_agent_id__()

  defp review_decision("approved"), do: :approved
  defp review_decision("denied"), do: :denied
end
