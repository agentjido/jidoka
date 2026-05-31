defmodule JidokaExampleWeb.AgentLive.Support do
  @moduledoc false

  use JidokaExampleWeb, :live_view

  alias JidokaExample.AgentSessions
  alias JidokaExampleWeb.AgentView.Support, as: View
  alias JidokaExampleWeb.SourceExamples

  @default_question "Can you check order A1001 and tell me what I should do next?"
  @tabs ~w(activity source)

  @impl true
  def mount(_params, session, socket) do
    session_id = Map.fetch!(session, "jidoka_example_session_id")
    agent_view = AgentSessions.get(session_id, fn -> initial_view(session_id) end)

    socket =
      assign(socket,
        agent_view: agent_view,
        active_tab: "activity",
        active_source: "agent",
        form: form(@default_question, JidokaExample.Env.model()),
        live_ready?: JidokaExample.Env.live_ready?(),
        page_title: "Support Agent",
        session_id: session_id,
        source_examples: SourceExamples.support_agent_sources()
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(active_tab: active_tab(params))
      |> assign(active_source: active_source(params))
      |> maybe_reset_session(params)
      |> maybe_run_prompt(params)

    {:noreply, socket}
  end

  defp maybe_reset_session(socket, %{"reset" => "1"}) do
    view =
      AgentSessions.reset(socket.assigns.session_id, fn ->
        initial_view(socket.assigns.session_id)
      end)

    assign(socket,
      agent_view: view,
      form: form(@default_question, JidokaExample.Env.model())
    )
  end

  defp maybe_reset_session(socket, _params), do: socket

  defp maybe_run_prompt(socket, %{"prompt" => params}) when is_map(params) do
    run_prompt(socket, params)
  end

  defp maybe_run_prompt(socket, _params), do: socket

  defp run_prompt(socket, params) do
    question = params |> Map.get("question", "") |> to_string() |> String.trim()
    model = params |> Map.get("model", "") |> to_string() |> String.trim()

    cond do
      question == "" ->
        assign(socket, form: form(question, model))

      not socket.assigns.live_ready? ->
        view =
          socket.assigns.agent_view
          |> View.before_turn(question)
          |> View.after_turn({:error, :missing_live_llm_credentials})

        AgentSessions.put(socket.assigns.session_id, view)

        assign(socket, agent_view: view, form: form(question, model))

      true ->
        view =
          View.run(socket.assigns.agent_view, question,
            llm_opts: [model: model],
            context: %{
              surface: "phoenix_live_view",
              example: "support_agent",
              session_id: socket.assigns.session_id
            }
          )

        AgentSessions.put(socket.assigns.session_id, view)

        assign(socket, agent_view: view, form: form("", model))
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
          <a class="quiet-link" href="/agents/support?reset=1">New session</a>
        </div>
      </header>

      <div class="grid">
        <section class="panel conversation-panel">
          <div class="panel-header">
            <div>
              <h2>Support session</h2>
              <p class="subtle">Ask, answer, inspect.</p>
            </div>
          </div>

          <div class="panel-body">
            <div class="messages">
              <%= if @agent_view.visible_messages == [] do %>
                <div class="empty">
                  <strong>Start with the sample order.</strong>
                  <span>
                    The first response should call the lookup tool and explain the next step.
                  </span>
                </div>
              <% end %>

              <%= for message <- @agent_view.visible_messages do %>
                <article class={"message #{message.role}"}>
                  <div class="message-role">{message.role}</div>
                  <div>{message.content}</div>
                </article>
              <% end %>
            </div>

            <%= if @agent_view.error_text do %>
              <div style="height: 12px"></div>
              <div class="empty">{@agent_view.error_text}</div>
            <% end %>

            <form
              class="composer"
              action="/agents/support"
              method="get"
              onsubmit="this.querySelector('button[type=submit]').disabled = true; this.querySelector('button[type=submit]').textContent = 'Running...';"
            >
              <input type="hidden" name="tab" value={@active_tab} />
              <input type="hidden" name="source" value={@active_source} />

              <div class="form-row">
                <label for="prompt_question">Message</label>
                <textarea
                  id="prompt_question"
                  name="prompt[question]"
                  placeholder="Ask about order A1001..."
                  onkeydown="if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') { event.preventDefault(); this.form.requestSubmit(); }"
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
            </form>
          </div>
        </section>

        <aside class="panel inspector-panel">
          <div class="panel-header">
            <div>
              <h2>Run internals</h2>
              <div class="tabs">
                <a class={tab_class(@active_tab, "activity")} href="/agents/support?tab=activity">
                  Activity
                </a>
                <a
                  class={tab_class(@active_tab, "source")}
                  href={"/agents/support?tab=source&source=#{@active_source}"}
                >
                  Source
                </a>
              </div>
            </div>

            <span class="subtle">{tab_count(@active_tab, @agent_view, @source_examples)}</span>
          </div>

          <div class="panel-body">
            <%= if @active_tab == "activity" do %>
              <.activity events={@agent_view.events} />
            <% else %>
              <.source_examples examples={@source_examples} active_source={@active_source} />
            <% end %>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  attr :status, :atom, required: true

  defp status(assigns) do
    ~H"""
    <span class={"status #{@status}"}>
      <span class="status-dot"></span>
      {@status}
    </span>
    """
  end

  defp form(question, model) do
    Phoenix.Component.to_form(%{"question" => question, "model" => model}, as: :prompt)
  end

  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp initial_view(session_id) do
    {:ok, agent_view} = View.initial(%{conversation_id: session_id})
    agent_view
  end

  defp active_tab(%{"tab" => tab}) when tab in @tabs, do: tab
  defp active_tab(_params), do: "activity"

  defp active_source(%{"source" => source}) when is_binary(source), do: source
  defp active_source(_params), do: "agent"

  defp tab_class(active_tab, tab), do: ["tab", active_tab == tab && "active"]

  defp tab_count("source", _agent_view, examples), do: "#{length(examples)} files"
  defp tab_count(_tab, agent_view, _examples), do: "#{length(agent_view.events)} events"

  attr :events, :list, required: true

  defp activity(assigns) do
    ~H"""
    <%= if @events == [] do %>
      <div class="empty">No activity yet.</div>
    <% else %>
      <div class="event-list">
        <%= for event <- @events do %>
          <article class="event">
            <div class="event-topline">
              <div>
                <h3>{event.label}</h3>
                <p class="subtle">{event.kind}</p>
              </div>

              <span class="pill">{event.refs.operation}</span>
            </div>

            <.operation_payload payload={event.payload} />
          </article>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :payload, :map, required: true

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

  attr :examples, :list, required: true
  attr :active_source, :string, required: true

  defp source_examples(assigns) do
    assigns =
      assign(assigns,
        selected: selected_source(assigns.examples, assigns.active_source)
      )

    ~H"""
    <div class="source-nav">
      <%= for example <- @examples do %>
        <a
          class={source_tab_class(@selected.id, example.id)}
          href={"/agents/support?tab=source&source=#{example.id}"}
        >
          {example.label}
        </a>
      <% end %>
    </div>

    <section class="source-file">
      <div class="source-file-header">
        <h3>{@selected.label}</h3>
        <span>{@selected.path}</span>
      </div>

      <pre class="code-block"><code><%= raw(highlight_elixir(@selected.source)) %></code></pre>
    </section>
    """
  end

  defp selected_source(examples, active_source) do
    Enum.find(examples, &(&1.id == active_source)) || hd(examples)
  end

  defp source_tab_class(active_source, source),
    do: ["source-nav-link", active_source == source && "active"]

  defp highlight_elixir(source) do
    source
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/(&quot;.*?&quot;)/, ~s(<span class="code-string">\\1</span>))
    |> String.replace(~r/(#.*)$/m, ~s(<span class="code-comment">\\1</span>))
    |> String.replace(
      ~r/\b(defmodule|defp?|use|alias|do|end|agent|tools|action|instructions|generation)\b/,
      ~s(<span class="code-keyword">\\1</span>)
    )
    |> String.replace(~r/(:[a-zA-Z_][a-zA-Z0-9_?!]*)/, ~s(<span class="code-atom">\\1</span>))
  end
end
