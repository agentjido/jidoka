defmodule JidokaExampleWeb.AgentComponents do
  @moduledoc false

  use JidokaExampleWeb, :html

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

  attr :examples, :list, required: true
  attr :active_source, :string, required: true

  def source_examples(assigns) do
    assigns =
      assign(assigns,
        selected: selected_source(assigns.examples, assigns.active_source)
      )

    ~H"""
    <div class="source-nav">
      <%= for example <- @examples do %>
        <button
          class={source_tab_class(@selected.id, example.id)}
          type="button"
          phx-click="show_source"
          phx-value-source={example.id}
        >
          {example.label}
        </button>
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

  attr :events, :list, required: true
  slot :operation_result

  def activity(assigns) do
    assigns = assign(assigns, activity_groups: activity_groups(assigns.events))

    ~H"""
    <%= if @activity_groups == [] do %>
      <div class="empty">No activity yet.</div>
    <% else %>
      <div class="event-groups">
        <%= for group <- @activity_groups do %>
          <details class="event-group">
            <summary class="event-group-summary">
              <span class="event-group-chevron" aria-hidden="true"></span>

              <span class="event-group-copy">
                <strong>{group.title}</strong>
                <span>{group.subtitle}</span>
              </span>

              <span class="event-group-meta">
                <%= if group.operation do %>
                  <span class="pill">{group.operation}</span>
                <% end %>

                <span>{group.count_label}</span>
              </span>
            </summary>

            <div class="event-group-body">
              <div class="event-list">
                <%= for event <- group.events do %>
                  <article class={["event", detailed_event?(event) && "detailed"]}>
                    <div class="event-topline">
                      <div>
                        <h3>{event.label}</h3>
                        <p class="subtle">{event.kind}</p>
                      </div>

                      <%= if is_nil(group.operation) do %>
                        <%= if operation = event_operation(event) do %>
                          <span class="pill">{operation}</span>
                        <% end %>
                      <% end %>
                    </div>

                    <%= if detailed_event?(event) do %>
                      {render_slot(@operation_result, event)}
                    <% end %>
                  </article>
                <% end %>
              </div>
            </div>
          </details>
        <% end %>
      </div>
    <% end %>
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
      ~r/\b(defmodule|defp?|use|alias|do|end|agent|tools|controls|action|browser|ash_resource|catalog|instructions|model|generation|max_turns|timeout)\b/,
      ~s(<span class="code-keyword">\\1</span>)
    )
    |> String.replace(~r/(:[a-zA-Z_][a-zA-Z0-9_?!]*)/, ~s(<span class="code-atom">\\1</span>))
  end

  defp activity_groups(events) do
    events
    |> Enum.reduce([], fn event, groups ->
      key = activity_group_key(event)

      case Enum.find_index(groups, &(&1.key == key)) do
        nil -> groups ++ [new_activity_group(key, event)]
        index -> List.update_at(groups, index, &append_activity_event(&1, event))
      end
    end)
    |> Enum.map(&finalize_activity_group/1)
  end

  defp new_activity_group(key, event) do
    %{
      key: key,
      title: activity_group_title(key),
      subtitle: activity_group_subtitle(key),
      operation: activity_group_operation(key),
      events: [event]
    }
  end

  defp append_activity_event(group, event), do: %{group | events: group.events ++ [event]}

  defp finalize_activity_group(group) do
    count = length(group.events)
    status = group.events |> List.last() |> event_status()

    count_label =
      [pluralize(count, "event"), status]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" / ")

    Map.put(group, :count_label, count_label)
  end

  defp activity_group_key(event) do
    request_id = event_request_id(event)

    cond do
      turn_event?(event.kind) ->
        {:turn, request_id}

      operation = event_operation(event) ->
        {:operation, request_id, operation}

      model_event?(event) ->
        {:model, request_id, event_loop_index(event)}

      true ->
        {:category, request_id, event_category(event)}
    end
  end

  defp activity_group_title({:turn, _request_id}), do: "Turn lifecycle"

  defp activity_group_title({:model, _request_id, loop_index}),
    do: "Model call #{loop_number(loop_index)}"

  defp activity_group_title({:operation, _request_id, operation}), do: "Tool: #{operation}"
  defp activity_group_title({:category, _request_id, category}), do: category |> humanize_event()

  defp activity_group_subtitle({:turn, _request_id}), do: "Start, finish, and runtime status"

  defp activity_group_subtitle({:model, _request_id, _loop_index}),
    do: "Prompt and LLM capability"

  defp activity_group_subtitle({:operation, _request_id, _operation}),
    do: "Tool lifecycle and result"

  defp activity_group_subtitle({:category, _request_id, category}),
    do: "#{humanize_event(category)} events"

  defp activity_group_operation({:operation, _request_id, operation}), do: operation
  defp activity_group_operation(_key), do: nil

  defp detailed_event?(%{kind: :operation_result}), do: true
  defp detailed_event?(_event), do: false

  defp event_operation(%{refs: %{operation: operation}}) when is_binary(operation), do: operation
  defp event_operation(%{payload: payload}), do: payload_value(payload, :operation)
  defp event_operation(_event), do: nil

  defp event_request_id(%{refs: %{request_id: request_id}}) when is_binary(request_id),
    do: request_id

  defp event_request_id(%{payload: payload}), do: payload_value(payload, :request_id) || "turn"
  defp event_request_id(_event), do: "turn"

  defp event_loop_index(%{payload: payload}), do: payload_value(payload, :loop_index) || 0
  defp event_loop_index(_event), do: 0

  defp event_category(%{payload: payload}), do: payload_value(payload, :category) || :runtime
  defp event_category(_event), do: :runtime

  defp event_status(%{kind: :operation_result}), do: "result"

  defp event_status(%{payload: payload}) do
    payload
    |> payload_value(:status)
    |> case do
      nil -> nil
      status -> humanize_event(status)
    end
  end

  defp event_status(_event), do: nil

  defp turn_event?(event)
       when event in [:turn_started, :turn_finished, :turn_failed, :turn_hibernated],
       do: true

  defp turn_event?(_event), do: false

  defp model_event?(%{kind: :prompt_assembled}), do: true

  defp model_event?(%{payload: payload}),
    do: payload_value(payload, :effect_kind) in [:llm, "llm"]

  defp model_event?(_event), do: false

  defp loop_number(index) when is_integer(index), do: index + 1

  defp loop_number(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} -> parsed + 1
      _other -> index
    end
  end

  defp loop_number(_index), do: 1

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(count, word), do: "#{count} #{word}s"

  defp humanize_event(event) do
    event
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
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

  defp payload_value(%{} = payload, key) when is_binary(key) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp payload_value(_payload, _key), do: nil
end
