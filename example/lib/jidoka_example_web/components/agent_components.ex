defmodule JidokaExampleWeb.AgentComponents do
  @moduledoc false

  use JidokaExampleWeb, :html

  alias JidokaExampleWeb.AgentActivityComponents
  alias JidokaExampleWeb.AgentSourceComponents
  alias JidokaExampleWeb.Markdown

  attr :status, :atom, required: true

  def status(assigns) do
    ~H"""
    <span class={"status #{@status}"}>
      <span class="status-dot"></span>
      {@status}
    </span>
    """
  end

  attr :messages, :list, required: true
  attr :empty_title, :string, required: true
  attr :empty_body, :string, required: true

  def messages(assigns) do
    ~H"""
    <div class="messages">
      <%= if @messages == [] do %>
        <div class="empty">
          <strong>{@empty_title}</strong>
          <span>{@empty_body}</span>
        </div>
      <% end %>

      <%= for message <- @messages do %>
        <article class={"message #{message.role}"}>
          <div class="message-role">{message.role}</div>
          <div class={message_content_class(message)}>
            <%= if markdown_message?(message) do %>
              {Markdown.render(message.content)}
            <% else %>
              {message.content}
            <% end %>
          </div>
        </article>
      <% end %>
    </div>
    """
  end

  attr :guide, :string, required: true

  def guide(assigns) do
    ~H"""
    <section class="guide" aria-label="Guide">
      <%= for paragraph <- guide_paragraphs(@guide) do %>
        <p>{paragraph}</p>
      <% end %>
    </section>
    """
  end

  attr :active_tab, :string, required: true
  attr :tab, :string, required: true
  slot :inner_block, required: true

  def tab_button(assigns) do
    ~H"""
    <button
      class={["tab", @active_tab == @tab && "active"]}
      type="button"
      phx-click="show_tab"
      phx-value-tab={@tab}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :guide, :string, required: true
  attr :status, :atom, required: true
  attr :panel_title, :string, required: true
  attr :panel_subtitle, :string, required: true
  attr :messages, :list, required: true
  attr :empty_title, :string, required: true
  attr :empty_body, :string, required: true
  attr :error_text, :string, default: nil
  attr :form, :any, required: true
  attr :field_label, :string, required: true
  attr :field_placeholder, :string, required: true
  attr :button_label, :string, required: true
  attr :active_tab, :string, required: true
  attr :active_source, :string, required: true
  attr :agent_view, :any, required: true
  attr :source_examples, :list, required: true
  slot :conversation_extra
  slot :operation_result

  def agent_page(assigns) do
    ~H"""
    <section class="page">
      <header class="page-header">
        <div>
          <p class="eyebrow">Agent route</p>
          <h1>{@title}</h1>
          <p class="subtle">{@subtitle}</p>
        </div>

        <div class="header-actions">
          <.status status={@status} />
          <button class="quiet-link" type="button" phx-click="reset_session">New session</button>
        </div>
      </header>

      <.guide guide={@guide} />

      <div class="grid">
        <section class="panel conversation-panel">
          <div class="panel-header">
            <div>
              <h2>{@panel_title}</h2>
              <p class="subtle">{@panel_subtitle}</p>
            </div>
          </div>

          <div class="panel-body">
            <.messages
              messages={@messages}
              empty_title={@empty_title}
              empty_body={@empty_body}
            />

            {render_slot(@conversation_extra)}

            <.agent_error error_text={@error_text} />

            <.composer
              form={@form}
              field_label={@field_label}
              field_placeholder={@field_placeholder}
              button_label={@button_label}
              running?={@status == :running}
            />
          </div>
        </section>

        <.inspector_panel
          active_tab={@active_tab}
          active_source={@active_source}
          agent_view={@agent_view}
          source_examples={@source_examples}
        >
          <:operation_result :let={event}>
            {render_slot(@operation_result, event)}
          </:operation_result>
        </.inspector_panel>
      </div>
    </section>
    """
  end

  attr :error_text, :string, default: nil

  def agent_error(%{error_text: nil} = assigns), do: ~H""

  def agent_error(assigns) do
    ~H"""
    <div class="empty agent-error">{@error_text}</div>
    """
  end

  attr :form, :any, required: true
  attr :field_label, :string, required: true
  attr :field_placeholder, :string, required: true
  attr :button_label, :string, required: true
  attr :running?, :boolean, default: false

  def composer(assigns) do
    ~H"""
    <.form for={@form} class="composer" phx-submit="send_message">
      <div class="form-row">
        <label for="prompt_question">{@field_label}</label>
        <textarea
          id="prompt_question"
          name="prompt[question]"
          placeholder={@field_placeholder}
        ><%= @form[:question].value %></textarea>
      </div>

      <details class="settings">
        <summary>
          <span>Model</span>
          <strong>{@form[:model].value}</strong>
        </summary>

        <div class="form-row compact">
          <label for="prompt_model">Model id</label>
          <input id="prompt_model" name="prompt[model]" type="text" value={@form[:model].value} />
        </div>
      </details>

      <div class="button-row">
        <button class="button" type="submit" disabled={@running?}>
          {@button_label}
        </button>
      </div>
    </.form>
    """
  end

  attr :active_tab, :string, required: true
  attr :active_source, :string, required: true
  attr :agent_view, :any, required: true
  attr :source_examples, :list, required: true
  slot :operation_result

  def inspector_panel(assigns) do
    ~H"""
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

        <span class="subtle">{inspector_count(@active_tab, @agent_view, @source_examples)}</span>
      </div>

      <div class="panel-body">
        <%= if @active_tab == "activity" do %>
          <AgentActivityComponents.activity events={@agent_view.events}>
            <:operation_result :let={event}>
              {render_slot(@operation_result, event)}
            </:operation_result>
          </AgentActivityComponents.activity>
        <% else %>
          <AgentSourceComponents.source_examples
            examples={@source_examples}
            active_source={@active_source}
          />
        <% end %>
      </div>
    </aside>
    """
  end

  defp markdown_message?(%{role: role}), do: role in [:assistant, "assistant"]

  defp message_content_class(message) do
    ["message-content", markdown_message?(message) && "markdown"]
  end

  defp guide_paragraphs(guide) do
    guide
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp inspector_count("source", _agent_view, examples), do: "#{length(examples)} files"
  defp inspector_count(_tab, agent_view, _examples), do: "#{length(agent_view.events)} events"
end
