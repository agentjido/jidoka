defmodule JidokaExampleWeb.SupportAgentLive.Index do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  import JidokaExampleWeb.AgentComponents

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
    session_id = Jidoka.Id.random("example_session")

    socket =
      assign(socket,
        agent_view: initial_view(session_id),
        active_tab: active_tab(params),
        active_source: active_source(params),
        active_request_id: nil,
        form: form(@default_question, default_model()),
        guide: agent_guide(),
        live_ready?: live_llm_ready?(),
        page_title: "Support Agent",
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
          <h1>Support Agent</h1>
          <p class="subtle">Customer support</p>
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
              <h2>Support session</h2>
              <p class="subtle">Ask, answer, inspect.</p>
            </div>
          </div>

          <div class="panel-body">
            <.messages
              messages={View.visible_messages(@agent_view)}
              empty_title="Start with the sample order."
              empty_body="The first response should call the lookup tool and explain the next step."
            />

            <%= if @agent_view.error_text do %>
              <div style="height: 12px"></div>
              <div class="empty">{@agent_view.error_text}</div>
            <% end %>

            <.form for={@form} class="composer" phx-submit="send_message">
              <div class="form-row">
                <label for="prompt_question">Message</label>
                <textarea
                  id="prompt_question"
                  name="prompt[question]"
                  placeholder="Ask about order A1001..."
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
                  Send
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
    assigns =
      assign(assigns,
        operation: payload_value(assigns.payload, :operation),
        status: payload_value(assigns.payload, [:output, :status]) || "ok",
        order:
          payload_value(assigns.payload, [:output, :order_id]) ||
            payload_value(assigns.payload, [:arguments, :order_id]),
        eta: payload_value(assigns.payload, [:output, :eta]) || "n/a",
        summary: payload_value(assigns.payload, [:output, :summary]),
        recommended_action: payload_value(assigns.payload, [:output, :recommended_action])
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
        with {:ok, pid} <- support_agent_pid() do
          Jidoka.run_turn(pid, question,
            request_id: request_id,
            stream: true,
            stream_to: parent,
            llm_opts: [model: model],
            context: %{
              surface: "phoenix_live_view",
              example: "support_agent",
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
      |> View.after_turn({:error, :missing_live_llm_credentials})

    assign(socket, agent_view: view, form: form(question, model))
  end

  defp source_examples do
    Enum.map(@sources, fn source ->
      source
      |> Map.put(:source, read_source(source.path))
      |> Map.put(:path, source.path)
    end)
  end

  defp agent_guide, do: JidokaExample.SupportAgent.Agent.guide()

  defp read_source(path) do
    case File.read(Path.join(@example_root, path)) do
      {:ok, source} -> source
      {:error, reason} -> "# Unable to read #{path}: #{inspect(reason)}"
    end
  end

  defp default_model do
    Application.get_env(:jidoka_example, :default_model, "openai:gpt-4o-mini")
  end

  defp live_llm_ready? do
    Application.get_env(:jidoka_example, :live_llm_ready?, false)
  end

  defp form(question, model) do
    Phoenix.Component.to_form(%{"question" => question, "model" => model}, as: :prompt)
  end

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp initial_view(session_id) do
    {:ok, agent_view} = View.initial(%{conversation_id: session_id})
    agent_view
  end

  defp support_agent_pid do
    case JidokaExample.Jido.whereis(support_agent_id()) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :support_agent_not_started}
    end
  end

  defp reset_agent_process do
    agent_id = support_agent_id()

    with :ok <- Supervisor.terminate_child(JidokaExample.Supervisor, agent_id),
         {:ok, _pid} <- Supervisor.restart_child(JidokaExample.Supervisor, agent_id) do
      :ok
    else
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp support_agent_id, do: JidokaExample.SupportAgent.Agent.spec().id

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
end
