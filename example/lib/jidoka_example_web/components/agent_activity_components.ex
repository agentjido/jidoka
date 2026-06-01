defmodule JidokaExampleWeb.AgentActivityComponents do
  @moduledoc false

  use JidokaExampleWeb, :html

  alias JidokaExampleWeb.AgentLive

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
  defp activity_group_title({:category, _request_id, category}), do: humanize_event(category)

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
  defp event_operation(%{payload: payload}), do: AgentLive.payload_value(payload, :operation)
  defp event_operation(_event), do: nil

  defp event_request_id(%{refs: %{request_id: request_id}}) when is_binary(request_id),
    do: request_id

  defp event_request_id(%{payload: payload}),
    do: AgentLive.payload_value(payload, :request_id) || "turn"

  defp event_request_id(_event), do: "turn"

  defp event_loop_index(%{payload: payload}),
    do: AgentLive.payload_value(payload, :loop_index) || 0

  defp event_loop_index(_event), do: 0

  defp event_category(%{payload: payload}),
    do: AgentLive.payload_value(payload, :category) || :runtime

  defp event_category(_event), do: :runtime

  defp event_status(%{kind: :operation_result}), do: "result"

  defp event_status(%{payload: payload}) do
    payload
    |> AgentLive.payload_value(:status)
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
    do: AgentLive.payload_value(payload, :effect_kind) in [:llm, "llm"]

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
end
