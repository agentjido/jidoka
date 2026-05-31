defmodule JidokaExampleWeb.ResearchAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

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
    session_id = Jidoka.Id.random("example_session")

    socket =
      assign(socket,
        agent_view: initial_view(session_id),
        active_tab: active_tab(params),
        active_source: active_source(params),
        active_request_id: nil,
        form: form(@default_question, default_model()),
        guide: agent_guide(),
        live_ready?: live_research_ready?(),
        page_title: "Research Agent",
        session_id: session_id,
        source_examples: source_examples()
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        active_tab: active_tab(params),
        active_source: active_source(params)
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_message", %{"prompt" => params}, socket) do
    {:noreply, run_prompt(socket, params)}
  end

  def handle_event("reset_session", _params, socket) do
    session_id = Jidoka.Id.random("example_session")

    case reset_agent_process() do
      :ok ->
        socket =
          assign(socket,
            agent_view: initial_view(session_id),
            active_request_id: nil,
            form: form(@default_question, default_model()),
            session_id: session_id
          )

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign_reset_error(socket, reason)}
    end
  end

  def handle_event("show_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: active_tab(%{"tab" => tab}))}
  end

  def handle_event("show_source", %{"source" => source}, socket) do
    socket =
      assign(socket,
        active_tab: "source",
        active_source: active_source(%{"source" => source})
      )

    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({@stream_message_tag, %Jidoka.Event{} = event}, socket) do
    if current_request?(socket, event.request_id) do
      {:noreply, assign(socket, agent_view: View.apply_event(socket.assigns.agent_view, event))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:jidoka_turn_result, request_id, result, model}, socket) do
    if current_request?(socket, request_id) do
      view = View.after_turn(socket.assigns.agent_view, result)

      {:noreply,
       assign(socket,
         agent_view: view,
         active_request_id: nil,
         form: form("", model)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="page">
      <header class="page-header">
        <div>
          <p class="eyebrow">Agent route</p>
          <h1>Research Agent</h1>
          <p class="subtle">Web research</p>
        </div>

        <div class="header-actions">
          <.status status={@agent_view.status} />
          <button class="quiet-link" type="button" phx-click="reset_session">New session</button>
        </div>
      </header>

      <.guide guide={@guide} />

      <div class="grid">
        <section class="panel conversation-panel">
          <div class="panel-header">
            <div>
              <h2>Research session</h2>
              <p class="subtle">Search, summarize, inspect.</p>
            </div>
          </div>

          <div class="panel-body">
            <.messages
              messages={View.visible_messages(@agent_view)}
              empty_title="Start with a focused question."
              empty_body="The first response should call web search and summarize sourced results."
            />

            <%= if @agent_view.error_text do %>
              <div style="height: 12px"></div>
              <div class="empty">{@agent_view.error_text}</div>
            <% end %>

            <.form for={@form} class="composer" phx-submit="send_message">
              <div class="form-row">
                <label for="prompt_question">Question</label>
                <textarea
                  id="prompt_question"
                  name="prompt[question]"
                  placeholder="Ask a research question..."
                ><%= @form[:question].value %></textarea>
              </div>

              <details class="settings">
                <summary>
                  <span>Model</span>
                  <strong>{@form[:model].value}</strong>
                </summary>

                <div class="form-row compact">
                  <label for="prompt_model">Model id</label>
                  <input
                    id="prompt_model"
                    name="prompt[model]"
                    type="text"
                    value={@form[:model].value}
                  />
                </div>
              </details>

              <div class="button-row">
                <button class="button" type="submit" disabled={@agent_view.status == :running}>
                  Search
                </button>
              </div>
            </.form>
          </div>
        </section>

        <aside class="panel inspector-panel">
          <div class="panel-header">
            <div>
              <h2>Run internals</h2>
              <div class="tabs">
                <.tab_button active_tab={@active_tab} tab="activity">
                  Activity
                </.tab_button>
                <.tab_button active_tab={@active_tab} tab="source">
                  Source
                </.tab_button>
              </div>
            </div>

            <span class="subtle">{tab_count(@active_tab, @agent_view, @source_examples)}</span>
          </div>

          <div class="panel-body">
            <%= if @active_tab == "activity" do %>
              <.activity events={@agent_view.events}>
                <:operation_result :let={event}>
                  <.operation_payload payload={event.payload} />
                </:operation_result>
              </.activity>
            <% else %>
              <.source_examples examples={@source_examples} active_source={@active_source} />
            <% end %>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  attr(:payload, :map, required: true)

  defp operation_payload(assigns) do
    operation = payload_value(assigns.payload, :operation)

    assigns =
      assign(assigns,
        operation: operation,
        page_result?: operation in ["read_page", "snapshot_url"],
        query:
          payload_value(assigns.payload, [:output, :query]) ||
            payload_value(assigns.payload, [:arguments, :query]),
        url:
          payload_value(assigns.payload, [:output, :url]) ||
            payload_value(assigns.payload, [:arguments, :url]),
        title: payload_value(assigns.payload, [:output, :title]),
        content_preview:
          assigns.payload
          |> payload_value([:output, :content])
          |> content_preview(),
        count: payload_value(assigns.payload, [:output, :count]) || 0,
        results: payload_value(assigns.payload, [:output, :results]) || []
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

  defp run_prompt(socket, params) do
    question = params |> Map.get("question", "") |> to_string() |> String.trim()
    model = params |> Map.get("model", "") |> to_string() |> String.trim()

    socket
    |> assign(form: form(question, model))
    |> run_prompt_with(question, model)
  end

  defp run_prompt_with(socket, "", model), do: assign(socket, form: form("", model))

  defp run_prompt_with(socket, question, model) do
    if socket.assigns.live_ready? do
      run_live_prompt(socket, question, model)
    else
      run_missing_credentials_prompt(socket, question, model)
    end
  end

  defp run_live_prompt(socket, question, model) do
    running = View.before_turn(socket.assigns.agent_view, question)
    request_id = View.request_id()
    parent = self()

    Task.start(fn ->
      result =
        with {:ok, pid} <- research_agent_pid() do
          Jidoka.run_turn(pid, question,
            request_id: request_id,
            stream: true,
            stream_to: parent,
            llm_opts: [model: model],
            context: %{
              surface: "phoenix_live_view",
              example: "research_agent",
              session_id: socket.assigns.session_id
            }
          )
        end

      send(parent, {:jidoka_turn_result, request_id, result, model})
    end)

    assign(socket, agent_view: running, active_request_id: request_id, form: form("", model))
  end

  defp run_missing_credentials_prompt(socket, question, model) do
    view =
      socket.assigns.agent_view
      |> View.before_turn(question)
      |> View.after_turn({:error, "Set an LLM key and BRAVE_SEARCH_API_KEY to run research."})

    assign(socket, agent_view: view, form: form(question, model))
  end

  defp source_examples do
    Enum.map(@sources, fn source ->
      source
      |> Map.put(:source, read_source(source))
      |> Map.put(:path, source.path)
    end)
  end

  defp agent_guide, do: JidokaExample.ResearchAgent.Agent.guide()

  defp read_source(%{path: path, root: :package}), do: read_source(@package_root, path)
  defp read_source(%{path: path}), do: read_source(@example_root, path)

  defp read_source(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, source} -> source
      {:error, reason} -> "# Unable to read #{path}: #{inspect(reason)}"
    end
  end

  defp default_model do
    Application.get_env(:jidoka_example, :default_model, "openai:gpt-4o-mini")
  end

  defp live_research_ready? do
    Application.get_env(:jidoka_example, :live_research_ready?, false)
  end

  defp form(question, model) do
    Phoenix.Component.to_form(%{"question" => question, "model" => model}, as: :prompt)
  end

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp initial_view(session_id) do
    {:ok, agent_view} = View.initial(%{conversation_id: session_id})
    agent_view
  end

  defp research_agent_pid do
    case JidokaExample.Jido.whereis(research_agent_id()) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :research_agent_not_started}
    end
  end

  defp reset_agent_process do
    agent_id = research_agent_id()

    with :ok <- Supervisor.terminate_child(JidokaExample.Supervisor, agent_id),
         {:ok, _pid} <- Supervisor.restart_child(JidokaExample.Supervisor, agent_id) do
      :ok
    else
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp research_agent_id, do: JidokaExample.ResearchAgent.Agent.__jidoka_agent_id__()

  defp assign_reset_error(socket, reason) do
    view = %{
      socket.assigns.agent_view
      | status: :error,
        error: reason,
        error_text: Jidoka.format_error(reason)
    }

    assign(socket, agent_view: view)
  end

  defp current_request?(socket, request_id) do
    is_binary(request_id) and socket.assigns[:active_request_id] == request_id
  end

  defp active_tab(%{"tab" => tab}) when tab in @tabs, do: tab
  defp active_tab(_params), do: "activity"

  defp active_source(%{"source" => source}) when is_binary(source) do
    if Enum.any?(@sources, &(&1.id == source)), do: source, else: "agent"
  end

  defp active_source(_params), do: "agent"

  defp tab_count("source", _agent_view, examples), do: "#{length(examples)} files"
  defp tab_count(_tab, agent_view, _examples), do: "#{length(agent_view.events)} events"

  defp payload_value(payload, path) when is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      case payload_value(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp payload_value(%{} = payload, key) when is_atom(key) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error -> Map.get(payload, Atom.to_string(key))
    end
  end

  defp payload_value(%{} = payload, key) when is_binary(key), do: Map.get(payload, key)
  defp payload_value(_payload, _key), do: nil

  defp result_value(result, key), do: payload_value(result, key)

  defp content_preview(nil), do: "No page content returned."

  defp content_preview(content) do
    content
    |> to_string()
    |> String.trim()
    |> String.slice(0, 900)
  end
end
