defmodule JidokaExampleWeb.LuaToolsAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

  alias JidokaExample.LuaToolsAgent.Agent
  alias JidokaExampleWeb.AgentLive
  alias JidokaExampleWeb.LuaToolsAgentLive.View

  @stream_message_tag Jidoka.Stream.message_tag()
  @default_question """
  Find Northwind customers, list unpaid invoices for each customer, draft a follow-up note with the hidden support note tool, and summarize every hidden Lua tool call you made.
  """
  @example_root Path.expand("../../../..", __DIR__)
  @package_root Path.expand("..", @example_root)
  @tabs ~w(activity source)
  @sources [
    %{id: "jido", label: "Jido", path: "lib/jidoka_example/jido.ex"},
    %{id: "application", label: "Application", path: "lib/jidoka_example/application.ex"},
    %{id: "agent", label: "Agent", path: "lib/jidoka_example/lua_tools_agent/agent.ex"},
    %{id: "catalog", label: "Lua Catalog", path: "lib/jidoka_example/lua_tools_agent/catalog.ex"},
    %{
      id: "runtime_wrapper",
      label: "Runtime Wrapper",
      path: "lib/jidoka_example/lua_tools_agent/lua_runtime.ex"
    },
    %{
      id: "workflow_lua",
      label: "Jidoka.Workflow.Lua",
      root: :package,
      path: "lib/jidoka/workflow/lua.ex"
    },
    %{
      id: "workflow_plan",
      label: "Lua Plan Runtime",
      root: :package,
      path: "lib/jidoka/workflow/lua/plan.ex"
    },
    %{
      id: "workflow_plan_spec",
      label: "Lua Plan Spec",
      root: :package,
      path: "lib/jidoka/workflow/lua/plan/spec.ex"
    },
    %{
      id: "workflow_plan_ref",
      label: "Lua Plan Refs",
      root: :package,
      path: "lib/jidoka/workflow/lua/plan/ref.ex"
    },
    %{
      id: "workflow_lua_policy",
      label: "Lua Policy",
      root: :package,
      path: "lib/jidoka/workflow/lua/policy.ex"
    },
    %{
      id: "query",
      label: "Query Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/lua_tools_query.ex"
    },
    %{
      id: "describe",
      label: "Describe Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/lua_tools_describe.ex"
    },
    %{
      id: "execute",
      label: "Execute Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/lua_tools_execute.ex"
    },
    %{
      id: "customer_search",
      label: "Hidden CRM Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/search_customers.ex"
    },
    %{
      id: "invoice_list",
      label: "Hidden Billing Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/list_unpaid_invoices.ex"
    },
    %{
      id: "followup_note",
      label: "Hidden Support Action",
      path: "lib/jidoka_example/lua_tools_agent/actions/draft_followup_note.ex"
    },
    %{
      id: "agent_view",
      label: "AgentView",
      path: "lib/jidoka_example_web/live/lua_tools_agent_live/view.ex"
    },
    %{
      id: "live_view",
      label: "LiveView",
      path: "lib/jidoka_example_web/live/lua_tools_agent_live/index.ex"
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
        page_title: "Lua Tools Agent",
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
       agent_pid: &lua_tools_agent_pid/0,
       example: "lua_tools_agent"
     )}
  end

  def handle_event("reset_session", _params, socket) do
    {:noreply,
     AgentLive.reset_session(
       socket,
       View,
       JidokaExample.Supervisor,
       lua_tools_agent_id(),
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
      title="Lua Tools Agent"
      subtitle="Dynamic scripting over hidden host tools"
      guide={@guide}
      status={@agent_view.status}
      panel_title="Lua tool session"
      panel_subtitle="Discover, describe, execute."
      messages={View.visible_messages(@agent_view)}
      empty_title="Start with the sample backoffice task."
      empty_body="The agent should query the hidden catalog, describe selected tools, then execute one Lua script."
      error_text={@agent_view.error_text}
      form={@form}
      field_label="Backoffice task"
      field_placeholder="Ask for a dynamic multi-tool task..."
      button_label="Run script"
      active_tab={@active_tab}
      active_source={@active_source}
      agent_view={@agent_view}
      source_examples={@source_examples}
    >
      <:conversation_extra>
        <.lua_structured_result value={AgentLive.result_value(@agent_view)} />
      </:conversation_extra>

      <:operation_result :let={event}>
        <.operation_payload payload={event.payload} />
      </:operation_result>
    </.agent_page>
    """
  end

  attr(:value, :any, required: true)

  defp lua_structured_result(%{value: nil} = assigns), do: ~H""

  defp lua_structured_result(assigns) do
    assigns =
      assign(assigns,
        summary: value(assigns.value, :summary),
        hidden_call_count: value(assigns.value, :hidden_call_count),
        hidden_tools_used: value(assigns.value, :hidden_tools_used) || [],
        script_result: value(assigns.value, :script_result),
        takeaways: value(assigns.value, :takeaways) || []
      )

    ~H"""
    <section class="tool-result structured-result" aria-label="Lua tool summary">
      <div class="kv-grid">
        <div>
          <span>Hidden calls</span>
          <strong>{@hidden_call_count || 0}</strong>
        </div>
        <div>
          <span>Tools used</span>
          <strong>{Enum.join(@hidden_tools_used, ", ")}</strong>
        </div>
      </div>

      <div class="tool-summary">
        <p>{@summary}</p>

        <%= if @takeaways != [] do %>
          <ul>
            <%= for takeaway <- @takeaways do %>
              <li>{takeaway}</li>
            <% end %>
          </ul>
        <% end %>
      </div>

      <%= if @script_result do %>
        <details>
          <summary>Structured script result</summary>
          <pre><%= AgentLive.pretty(@script_result) %></pre>
        </details>
      <% end %>
    </section>
    """
  end

  attr(:payload, :map, required: true)

  defp operation_payload(assigns) do
    operation = AgentLive.payload_value(assigns.payload, :operation)
    output = AgentLive.payload_value(assigns.payload, :output) || %{}

    assigns =
      assign(assigns,
        operation: operation,
        output: output,
        tool_count: length(AgentLive.payload_value(output, :tools) || []),
        call_count: AgentLive.payload_value(output, :call_count) || 0,
        status: AgentLive.payload_value(output, :status),
        script: AgentLive.payload_value(output, :script),
        calls: AgentLive.payload_value(output, :calls) || [],
        result: AgentLive.payload_value(output, :result)
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
          <strong>{@status || "ok"}</strong>
        </div>
        <div>
          <span>Tools</span>
          <strong>{@tool_count}</strong>
        </div>
        <div>
          <span>Hidden calls</span>
          <strong>{@call_count}</strong>
        </div>
      </div>

      <%= if @operation == "lua_tools_execute" do %>
        <%= if @script do %>
          <div class="script-block">
            <span>Lua script</span>
            <pre><code><%= @script %></code></pre>
          </div>
        <% end %>

        <%= if @calls != [] do %>
          <div class="call-list">
            <%= for call <- @calls do %>
              <article class="call-row">
                <div>
                  <strong>{value(call, :tool)}</strong>
                  <span>{value(call, :status)}</span>
                </div>
                <pre><%= AgentLive.pretty(%{
                  "arguments" => value(call, :arguments),
                  "output" => value(call, :output)
                }) %></pre>
              </article>
            <% end %>
          </div>
        <% end %>

        <%= if @result do %>
          <details open>
            <summary>Lua return value</summary>
            <pre><%= AgentLive.pretty(@result) %></pre>
          </details>
        <% end %>
      <% else %>
        <div class="tool-summary">
          <p>{operation_summary(@operation, @output)}</p>
        </div>
      <% end %>

      <details>
        <summary>Raw projection</summary>
        <pre><%= AgentLive.pretty(@payload) %></pre>
      </details>
    </div>
    """
  end

  defp operation_summary("lua_tools_query", output) do
    "Found #{length(value(output, :tools) || [])} candidate hidden tools."
  end

  defp operation_summary("lua_tools_describe", output) do
    ids = output |> value(:allowed_tools) |> List.wrap() |> Enum.join(", ")
    "Described selected hidden tools: #{ids}."
  end

  defp operation_summary(_operation, _output), do: "Operation completed."

  defp value(payload, key), do: AgentLive.payload_value(payload, key)

  defp lua_tools_agent_pid,
    do: AgentLive.agent_pid(lua_tools_agent_id(), :lua_tools_agent_not_started)

  defp lua_tools_agent_id, do: Agent.__jidoka_agent_id__()
end
