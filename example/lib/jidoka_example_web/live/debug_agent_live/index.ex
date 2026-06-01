defmodule JidokaExampleWeb.DebugAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.DebugAgent.Agent
  alias JidokaExample.DebugAgent.Targets
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.DebugAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Inspect the support agent and preflight this prompt: Can you check order A1001?"
  @preview_prompt "Can you check order A1001?"
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/debug_agent/agent.ex"},
    %{id: "targets", label: "Targets", path: "lib/jidoka_example/debug_agent/targets.ex"},
    %{
      id: "inspect_action",
      label: "Inspect Action",
      path: "lib/jidoka_example/debug_agent/actions/inspect_agent.ex"
    },
    %{
      id: "preflight_action",
      label: "Preflight Action",
      path: "lib/jidoka_example/debug_agent/actions/preflight_agent.ex"
    },
    %{id: "inspect_api", label: "Inspect API", path: "lib/jidoka/inspection.ex", root: :package},
    %{
      id: "preflight_api",
      label: "Preflight API",
      path: "lib/jidoka/inspection/preflight.ex",
      root: :package
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/debug_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/debug_agent_live/index.ex"
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
        page_title: "Debug Agent",
        sources: @sources,
        tabs: @tabs
      )
      |> assign(debug_preview: Targets.preview("support", @preview_prompt))

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
       agent_pid: &debug_agent_pid/0,
       example: "debug_agent"
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       debug_agent_id(),
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
      title="Debug Agent"
      subtitle="Inspect and preflight"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Debug session"
      panel_subtitle="Inspect, preflight, verify."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with a support-agent debug check."
      empty_body="The static preview below shows inspect/preflight without a live LLM call."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Request"
      field_placeholder="Ask to inspect support, research, kitchen_sink..."
      button_label="Debug"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.debug_result value={AgentLive.result_value(@agent_view)} />
        <.debug_preview preview={@debug_preview} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr :value, :any, required: true

  defp debug_result(%{value: nil} = assigns), do: ~H""

  defp debug_result(assigns) do
    assigns =
      assign(assigns,
        summary: value(assigns.value, :summary),
        target: value(assigns.value, :target),
        checks: value(assigns.value, :checks) || [],
        operations: value(assigns.value, :operations) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Debug result">
      <div class="kv-grid">
        <div>
          <span>Structured result</span>
          <strong>{@target}</strong>
        </div>
        <div>
          <span>Operations</span>
          <strong>{length(@operations)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Summary:</strong> {@summary}</p>

        <%= for check <- @checks do %>
          <p><strong>{value(check, :name)}:</strong> {value(check, :value)}</p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :preview, :map, required: true

  defp debug_preview(assigns) do
    inspection = Map.get(assigns.preview, :inspect, Map.get(assigns.preview, "inspect", %{}))
    preflight = Map.get(assigns.preview, :preflight, Map.get(assigns.preview, "preflight", %{}))

    assigns =
      assign(assigns,
        inspection: inspection,
        preflight: preflight,
        operations: value(inspection, :operations) || [],
        messages: value(preflight, :messages) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Static debug preview">
      <div class="kv-grid">
        <div>
          <span>Static inspect</span>
          <strong>{value(@inspection, :label)}</strong>
        </div>
        <div>
          <span>Preflight messages</span>
          <strong>{length(@messages)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p>
          <strong>Operations:</strong>
          <%= if @operations == [] do %>
            none
          <% else %>
            {@operations |> Enum.map(&value(&1, :name)) |> Enum.join(", ")}
          <% end %>
        </p>
        <p>
          <strong>Prompt:</strong>
          {@messages
          |> Enum.map(&"#{value(&1, :role)}=#{preview(value(&1, :content))}")
          |> Enum.join(" | ")}
        </p>
      </div>
    </section>
    """
  end

  attr :payload, :map, required: true

  defp operation_payload(assigns) do
    output = AgentLive.payload_value(assigns.payload, :output) || %{}
    operation = AgentLive.payload_value(assigns.payload, :operation)

    assigns =
      assign(assigns,
        operation: operation,
        target: AgentLive.payload_value(output, :target),
        label: AgentLive.payload_value(output, :label),
        operation_count: AgentLive.payload_value(output, :operation_count),
        message_count: AgentLive.payload_value(output, :message_count),
        operations: AgentLive.payload_value(output, :operations) || [],
        messages: AgentLive.payload_value(output, :messages) || []
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Target</span>
          <strong>{@label || @target}</strong>
        </div>
        <div>
          <span>Tools</span>
          <strong>{@operation_count || length(@operations)}</strong>
        </div>
        <div>
          <span>Messages</span>
          <strong>{@message_count || length(@messages)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= if @operations != [] do %>
          <p>
            <strong>Operations:</strong>
            {@operations |> Enum.map(&"#{value(&1, :name)} (#{value(&1, :kind)})") |> Enum.join(", ")}
          </p>
        <% end %>

        <%= if @messages != [] do %>
          <p>
            <strong>Prompt:</strong>
            {@messages
            |> Enum.map(&"#{value(&1, :role)}=#{preview(value(&1, :content))}")
            |> Enum.join(" | ")}
          </p>
        <% end %>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp debug_agent_pid, do: AgentLive.agent_pid(debug_agent_id(), :debug_agent_not_started)
  defp debug_agent_id, do: Agent.__jidoka_agent_id__()

  defp value(map, key), do: AgentLive.payload_value(map, key)

  defp preview(nil), do: ""

  defp preview(content) do
    content
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end
end
