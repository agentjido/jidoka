defmodule JidokaExampleWeb.MemoryAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.MemoryAgent.Agent
  alias JidokaExample.MemoryAgent.Memory
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.MemoryAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question "Remember that I prefer concise answers with one clear next step."
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/memory_agent/agent.ex"},
    %{id: "memory", label: "Memory Store", path: "lib/jidoka_example/memory_agent/memory.ex"},
    %{
      id: "action",
      label: "Remember Action",
      path: "lib/jidoka_example/memory_agent/actions/remember_preference.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/memory_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/memory_agent_live/index.ex"
    },
    %{
      id: "adapter",
      label: "Jido Memory Adapter",
      path: "lib/jidoka/memory/store/jido_memory.ex",
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
        page_title: "Memory Agent",
        sources: @sources,
        tabs: @tabs
      )
      |> assign(memory_entries: [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, AgentLive.apply_route(socket, params, @tabs, @sources)}
  end

  @impl true
  def handle_event("send_message", %{"prompt" => params}, socket) do
    memory_store = Memory.store()

    {:noreply,
     AgentLive.run_prompt(socket, params, View,
       agent_pid: &memory_agent_pid/0,
       example: "memory_agent",
       memory_store: memory_store,
       operation_context: %{memory_store: memory_store}
     )}
  end

  def handle_event("reset_session", _params, socket) do
    socket =
      socket
      |> AgentLive.reset_session(
        View,
        JidokaExample.Supervisor,
        memory_agent_id(),
        @default_question
      )
      |> assign(memory_entries: [])

    {:noreply, socket}
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
    socket =
      socket
      |> AgentLive.finish_turn(View, request_id, result, model)
      |> assign(memory_entries: load_memory_entries(socket.assigns.session_id))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_page
      title="Memory Agent"
      subtitle="Session memory"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Memory session"
      panel_subtitle="Remember, recall, inspect."
      messages={View.visible_messages(@agent_view)}
      empty_title="Store a preference first."
      empty_body="Then ask what style it should use and watch memory appear in the prompt."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Message"
      field_placeholder="Tell it a preference to remember..."
      button_label="Send"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.memory_entries entries={@memory_entries} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr :entries, :list, required: true

  defp memory_entries(assigns) do
    ~H"""
    <section class="tool-result structured-result" aria-label="Session memory">
      <div class="kv-grid">
        <div>
          <span>Session memory</span>
          <strong>{length(@entries)}</strong>
        </div>
        <div>
          <span>Backend</span>
          <strong>jido_memory</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= if @entries == [] do %>
          <p>No preferences stored for this session yet.</p>
        <% else %>
          <%= for entry <- @entries do %>
            <p>{entry.content}</p>
          <% end %>
        <% end %>
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
        remembered: AgentLive.payload_value(output, :remembered),
        memory_id: AgentLive.payload_value(output, :memory_id),
        content: AgentLive.payload_value(output, :content)
      )

    ~H"""
    <div class="tool-result">
      <div class="kv-grid">
        <div>
          <span>Operation</span>
          <strong>{@operation}</strong>
        </div>
        <div>
          <span>Remembered</span>
          <strong>{@remembered}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>{@memory_id}</strong></p>
        <p>{@content}</p>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp memory_agent_pid, do: AgentLive.agent_pid(memory_agent_id(), :memory_agent_not_started)
  defp memory_agent_id, do: Agent.__jidoka_agent_id__()

  defp load_memory_entries(session_id) do
    case Jidoka.Memory.Store.list_entries(Memory.store(session_id)) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end
end
