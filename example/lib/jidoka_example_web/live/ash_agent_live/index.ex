defmodule JidokaExampleWeb.AshAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.AshAgent.Agent
  alias JidokaExample.AshAgent.Domain
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.AshAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Create a customer named Ada Lovelace at Northwind. Tier enterprise, health score 91, notes: expansion candidate."
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/ash_agent/agent.ex"},
    %{id: "domain", label: "Ash Domain", path: "lib/jidoka_example/ash_agent/domain.ex"},
    %{
      id: "resource",
      label: "Ash Resource",
      path: "lib/jidoka_example/ash_agent/resources/customer.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/ash_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/ash_agent_live/index.ex"
    },
    %{
      id: "tool_sources",
      label: "Tool Sources",
      path: "lib/jidoka/agent/tool_sources.ex",
      root: :package
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
        page_title: "Ash Agent",
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
       agent_pid: &ash_agent_pid/0,
       example: "ash_agent",
       operation_context: %{domain: Domain}
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       ash_agent_id(),
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
      title="Ash Agent"
      subtitle="Ash resource tools"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Ash session"
      panel_subtitle="Create, list, inspect."
      messages={View.visible_messages(@agent_view)}
      empty_title="Create the sample customer."
      empty_body="The agent should call an AshJido generated Jido action through ash_resource."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Request"
      field_placeholder="Create or list customers..."
      button_label="Run"
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

  attr :payload, :map, required: true

  defp operation_payload(assigns) do
    output = AgentLive.payload_value(assigns.payload, :output) || %{}
    result = AgentLive.payload_value(output, :result) || output

    assigns =
      assign(assigns,
        operation: AgentLive.payload_value(assigns.payload, :operation),
        result: result,
        count: result_count(result),
        customer: first_result(result)
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Returned</span>
          <strong>{@count}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= if @customer do %>
          <p><strong>{value(@customer, :name)}</strong> at {value(@customer, :company)}</p>
          <p>Tier {value(@customer, :tier)}. Health score {value(@customer, :health_score)}.</p>
          <p>{value(@customer, :notes)}</p>
        <% else %>
          <p>No customer data returned.</p>
        <% end %>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp ash_agent_pid, do: AgentLive.agent_pid(ash_agent_id(), :ash_agent_not_started)
  defp ash_agent_id, do: Agent.__jidoka_agent_id__()

  defp result_count(result) when is_list(result), do: length(result)
  defp result_count(%{}), do: 1
  defp result_count(_result), do: 0

  defp first_result([first | _rest]), do: first
  defp first_result(%{} = result), do: result
  defp first_result(_result), do: nil

  defp value(map, key), do: AgentLive.payload_value(map, key)
end
