defmodule JidokaExampleWeb.KitchenSinkAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.AshAgent.Domain
  alias JidokaExample.KitchenSinkAgent.Agent
  alias JidokaExample.MemoryAgent.Memory
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.KitchenSinkAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question """
  Run the kitchen sink demo: look up the showcase policy, call the MCP showcase notes tool, ask the evidence specialist what to cite for the feature summary, record the refund specialist as owner for future refund follow-up, run the deterministic feature summary workflow, remember that I prefer concise answers, show the runtime context, look up order A1001, enrich and score Ada from Northwind, list the CRM customers, search the web for Runic workflows in Elixir, and return the structured feature summary.
  """
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/kitchen_sink_agent/agent.ex"},
    %{
      id: "skill",
      label: "Skill",
      path: "lib/jidoka_example/kitchen_sink_agent/skills/showcase_skill.ex"
    },
    %{
      id: "skill_action",
      label: "Skill Action",
      path: "lib/jidoka_example/kitchen_sink_agent/skills/showcase_policy_lookup.ex"
    },
    %{
      id: "mcp_client",
      label: "MCP Client",
      path: "lib/jidoka_example/kitchen_sink_agent/mcp/local_client.ex"
    },
    %{
      id: "subagent",
      label: "Subagent",
      path: "lib/jidoka_example/kitchen_sink_agent/subagents/evidence_agent.ex"
    },
    %{
      id: "handoff_control",
      label: "Handoff Control",
      path: "lib/jidoka_example/kitchen_sink_agent/controls/allow_specialist_handoff.ex"
    },
    %{
      id: "workflow",
      label: "Workflow",
      path: "lib/jidoka_example/kitchen_sink_agent/workflows/feature_summary_workflow.ex"
    },
    %{
      id: "context_action",
      label: "Context Action",
      path: "lib/jidoka_example/kitchen_sink_agent/actions/show_context.ex"
    },
    %{
      id: "lookup_action",
      label: "Lookup Action",
      path: "lib/jidoka_example/support_agent/actions/lookup_order.ex"
    },
    %{
      id: "lead_enrich",
      label: "Lead Enrich",
      path: "lib/jidoka_example/lead_quality_agent/actions/enrich_lead.ex"
    },
    %{
      id: "lead_score",
      label: "Lead Score",
      path: "lib/jidoka_example/lead_quality_agent/actions/score_lead.ex"
    },
    %{
      id: "input_control",
      label: "Input Control",
      path: "lib/jidoka_example/kitchen_sink_agent/controls/block_internal_prompt.ex"
    },
    %{
      id: "output_control",
      label: "Output Control",
      path: "lib/jidoka_example/kitchen_sink_agent/controls/require_showcase_summary.ex"
    },
    %{
      id: "review_control",
      label: "Review Control",
      path: "lib/jidoka_example/approval_agent/controls/require_refund_approval.ex"
    },
    %{
      id: "memory_action",
      label: "Memory Action",
      path: "lib/jidoka_example/memory_agent/actions/remember_preference.ex"
    },
    %{
      id: "ash_resource",
      label: "Ash Resource",
      path: "lib/jidoka_example/ash_agent/resources/customer.ex"
    },
    %{id: "browser", label: "Browser Tools", path: "lib/jidoka/browser.ex", root: :package},
    %{
      id: "memory_store",
      label: "Memory Store",
      path: "lib/jidoka/memory/store/jido_memory.ex",
      root: :package
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/kitchen_sink_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/kitchen_sink_agent_live/index.ex"
    }
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      AgentLive.mount_agent(socket, params, View,
        credentials: :research,
        default_question: @default_question,
        example_root: @example_root,
        guide: Agent.guide(),
        package_root: @package_root,
        page_title: "Kitchen Sink Agent",
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
       agent_pid: &kitchen_sink_agent_pid/0,
       context: kitchen_sink_context(socket.assigns.session_id),
       example: "kitchen_sink_agent",
       memory_store: memory_store,
       missing_error: "Set an LLM key and BRAVE_SEARCH_API_KEY to run the full showcase.",
       operation_context: %{
         domain: Domain,
         mcp_client: JidokaExample.KitchenSinkAgent.MCP.LocalClient,
         memory_store: memory_store
       }
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
    socket =
      socket
      |> AgentLive.reset_session(
        View,
        JidokaExample.Supervisor,
        kitchen_sink_agent_id(),
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
      title="Kitchen Sink Agent"
      subtitle="Full V2 surface"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Showcase session"
      panel_subtitle="Run, review, inspect."
      messages={View.visible_messages(@agent_view)}
      empty_title="Run the showcase prompt."
      empty_body="The agent should use multiple operation sources and return structured output."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Request"
      field_placeholder="Ask for a multi-feature showcase..."
      button_label="Run showcase"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.pending_review agent_view={@agent_view} />
        <.showcase_summary value={AgentLive.result_value(@agent_view)} />
        <.memory_entries entries={@memory_entries} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr :agent_view, :map, required: true

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

  attr :value, :any, required: true

  defp showcase_summary(%{value: nil} = assigns), do: ~H""

  defp showcase_summary(assigns) do
    assigns =
      assign(assigns,
        summary: value(assigns.value, :summary),
        features: value(assigns.value, :features) || [],
        sources: value(assigns.value, :sources) || [],
        next_steps: value(assigns.value, :next_steps) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Kitchen sink summary">
      <div class="kv-grid">
        <div>
          <span>Structured result</span>
          <strong>Showcase summary</strong>
        </div>
        <div>
          <span>Features</span>
          <strong>{length(@features)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p><strong>Summary:</strong> {@summary}</p>

        <%= if @features != [] do %>
          <ul>
            <%= for feature <- @features do %>
              <li>
                <strong>{value(feature, :name)}:</strong> {value(feature, :evidence)}
              </li>
            <% end %>
          </ul>
        <% end %>

        <%= if @sources != [] do %>
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
        <% end %>

        <%= if @next_steps != [] do %>
          <ol>
            <%= for step <- @next_steps do %>
              <li>{step}</li>
            <% end %>
          </ol>
        <% end %>
      </div>
    </section>
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
          <p>No memory entries stored for this session yet.</p>
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
    result = AgentLive.payload_value(output, :result) || output
    operation = AgentLive.payload_value(assigns.payload, :operation)

    assigns =
      assign(assigns,
        operation: operation,
        status: AgentLive.payload_value(output, :status) || "ok",
        returned: result_count(result),
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
          <span>Status</span>
          <strong>{@status}</strong>
        </div>
        <div>
          <span>Returned</span>
          <strong>{@returned}</strong>
        </div>
        <div>
          <span>Source</span>
          <strong>{operation_source(@operation)}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <%= if @summary_items == [] do %>
          <p>Operation completed. Open the raw projection for details.</p>
        <% else %>
          <%= for item <- @summary_items do %>
            <p>{item}</p>
          <% end %>
        <% end %>
      </div>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp kitchen_sink_agent_pid,
    do: AgentLive.agent_pid(kitchen_sink_agent_id(), :kitchen_sink_agent_not_started)

  defp kitchen_sink_agent_id, do: Agent.__jidoka_agent_id__()

  defp kitchen_sink_context(session_id) do
    %{
      tenant: "demo",
      channel: "kitchen_sink",
      session_id: session_id,
      actor: %{id: "example-developer", role: "developer"}
    }
  end

  defp review_decision("approved"), do: :approved
  defp review_decision("denied"), do: :denied

  defp load_memory_entries(session_id) do
    case Jidoka.Memory.Store.list_entries(Memory.store(session_id)) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp value(map, key), do: AgentLive.payload_value(map, key)

  defp result_count(result) when is_list(result), do: length(result)

  defp result_count(%{} = result),
    do: result |> value(:count) || result |> list_count(:actions) || 1

  defp result_count(_result), do: 0

  defp list_count(result, key) do
    case value(result, key) do
      list when is_list(list) -> length(list)
      _other -> nil
    end
  end

  defp summary_items("lookup_order", result) do
    [
      compact_line("Order", value(result, :order_id)),
      compact_line("Status", value(result, :status)),
      value(result, :summary),
      value(result, :recommended_action)
    ]
    |> compact()
  end

  defp summary_items("remember_preference", result) do
    [
      compact_line("Memory", value(result, :memory_id)),
      value(result, :content)
    ]
    |> compact()
  end

  defp summary_items("show_context", result) do
    [
      compact_line("Tenant", value(result, :tenant)),
      compact_line("Channel", value(result, :channel)),
      compact_line("Actor", result |> value(:actor) |> actor_label()),
      compact_line("Example", value(result, :example)),
      compact_line("Session", value(result, :session_id)),
      "Public keys: #{Enum.join(value(result, :keys) || [], ", ")}"
    ]
    |> compact()
  end

  defp summary_items("showcase_policy_lookup", result) do
    evidence = value(result, :required_evidence) || []

    ([
       compact_line("Topic", value(result, :topic)),
       value(result, :policy)
     ] ++ evidence)
    |> compact()
  end

  defp summary_items("mcp_showcase_notes", result) do
    result = value(result, :result) || result
    evidence = value(result, :evidence) || []

    ([
       compact_line("Topic", value(result, :topic)),
       value(result, :note)
     ] ++ evidence)
    |> compact()
  end

  defp summary_items("evidence_specialist", result) do
    value = value(result, :value) || %{}

    [
      value(result, :content),
      compact_line("Answer", value(value, :answer)),
      compact_line("Next check", value(value, :next_check))
    ]
    |> compact()
  end

  defp summary_items("refund_specialist", result) do
    handoff = value(result, :handoff) || %{}
    owner = value(result, :owner) || %{}

    [
      compact_line("Owner", value(owner, :agent_id)),
      compact_line("Conversation", value(handoff, :conversation_id)),
      compact_line("Message", value(handoff, :message)),
      compact_line("Summary", value(handoff, :summary))
    ]
    |> compact()
  end

  defp summary_items("build_feature_summary", result) do
    output = value(result, :output) || %{}

    [
      compact_line("Workflow", value(result, :workflow)),
      compact_line("Feature count", value(output, :feature_count)),
      value(output, :summary)
    ]
    |> compact()
  end

  defp summary_items("enrich_lead", result) do
    [
      compact_line("Company", value(result, :company)),
      compact_line("Industry", value(result, :industry)),
      compact_line("Budget", value(result, :budget_signal)),
      value(result, :fit_notes)
    ]
    |> compact()
  end

  defp summary_items("score_lead", result) do
    [
      compact_line("Company", value(result, :company)),
      compact_line("Score", value(result, :score)),
      compact_line("Grade", value(result, :grade)),
      value(result, :recommended_action)
    ]
    |> compact()
  end

  defp summary_items("list_customers", result) when is_list(result) do
    result
    |> Enum.take(4)
    |> Enum.map(fn customer ->
      "#{value(customer, :name)} at #{value(customer, :company)} (#{value(customer, :tier)})"
    end)
  end

  defp summary_items("create_customer", result) do
    ["#{value(result, :name)} at #{value(result, :company)} was returned from Ash."]
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

  defp summary_items("issue_refund", result) do
    [
      compact_line("Approval", value(result, :approval_id)),
      compact_line("Order", value(result, :order_id)),
      compact_line("Amount", value(result, :amount)),
      compact_line("Status", value(result, :status)),
      value(result, :reason)
    ]
    |> compact()
  end

  defp summary_items(_operation, _result), do: []

  defp operation_source(operation) when operation in ["search_web", "read_page", "snapshot_url"],
    do: "browser"

  defp operation_source("showcase_policy_lookup"), do: "skill"

  defp operation_source("mcp_showcase_notes"), do: "mcp"

  defp operation_source("evidence_specialist"), do: "subagent"

  defp operation_source("refund_specialist"), do: "handoff"

  defp operation_source("build_feature_summary"), do: "workflow"

  defp operation_source(operation) when operation in ["create_customer", "list_customers"],
    do: "ash"

  defp operation_source(_operation), do: "action"

  defp compact_line(_label, nil), do: nil
  defp compact_line(_label, ""), do: nil
  defp compact_line(label, value), do: "#{label}: #{value}"

  defp actor_label(nil), do: nil
  defp actor_label(actor), do: value(actor, :id)

  defp compact(values), do: Enum.reject(values, &(&1 in [nil, ""]))

  defp preview(nil), do: nil

  defp preview(content) do
    content
    |> to_string()
    |> String.trim()
    |> String.slice(0, 700)
  end
end
