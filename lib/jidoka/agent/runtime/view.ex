defmodule Jidoka.Agent.View do
  @moduledoc """
  Thread-backed projections for UI-facing agent views.

  `Jido.Thread` is the canonical event log for an agent. Jidoka projects that log
  into separate shapes for different consumers:

  - `:llm_context` is the provider-facing conversation projection.
  - `:visible_messages` is the user-facing chat transcript projection.
  - `:events` is a compact debug stream for tool calls, tool results, and
    context operations.

  This module is intentionally projection-only. `Jidoka.AgentView` builds on top
  of this projection to provide a reusable, rendering-free application surface
  for LiveView, controllers, CLI sessions, tests, channels, or jobs.
  """

  alias Jido.Thread
  alias Jido.Thread.Agent, as: ThreadAgent

  @default_context_ref "default"

  @typedoc "A provider-facing message projected from `Jido.Thread`."
  @type llm_message :: %{
          required(:id) => String.t() | nil,
          required(:seq) => non_neg_integer(),
          required(:role) => :user | :assistant | :tool,
          required(:content) => String.t(),
          required(:context_ref) => String.t(),
          required(:request_id) => String.t() | nil,
          required(:run_id) => String.t() | nil,
          optional(:tool_calls) => [map()],
          optional(:tool_call_id) => String.t(),
          optional(:name) => String.t(),
          optional(:thinking) => String.t()
        }

  @typedoc "A user-facing message projected from `Jido.Thread`."
  @type visible_message :: %{
          id: String.t() | nil,
          seq: non_neg_integer(),
          role: :user | :assistant,
          content: String.t(),
          request_id: String.t() | nil,
          run_id: String.t() | nil
        }

  @typedoc "An in-flight assistant message projected from ReAct strategy streaming state."
  @type streaming_message :: %{
          required(:id) => String.t(),
          required(:seq) => -1,
          required(:role) => :assistant,
          required(:content) => String.t(),
          required(:request_id) => String.t() | nil,
          required(:run_id) => String.t() | nil,
          required(:streaming?) => true,
          optional(:thinking) => String.t()
        }

  @typedoc "A compact non-chat event projected from `Jido.Thread`."
  @type event :: %{
          id: String.t() | nil,
          seq: non_neg_integer(),
          kind: atom(),
          label: String.t(),
          payload: map(),
          refs: map()
        }

  @typedoc "Agent view snapshot suitable for UI assignment."
  @type snapshot :: %{
          kind: :agent_view,
          agent_id: term(),
          agent_name: String.t() | nil,
          context_ref: String.t(),
          thread_id: String.t() | nil,
          thread_rev: non_neg_integer(),
          entry_count: non_neg_integer(),
          llm_context: [llm_message()],
          visible_messages: [visible_message()],
          streaming_message: streaming_message() | nil,
          events: [event()]
        }

  @doc """
  Projects the current agent thread from a running agent server, agent id, or
  `%Jido.Agent{}`.

  Options:

  - `:context_ref` selects the LLM context branch. Defaults to the strategy's
    active context ref, then `"default"`.
  - `:include_private` includes assistant thinking text in `:llm_context`.
    Defaults to `false`.
  """
  @spec snapshot(pid() | String.t() | Jido.Agent.t(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(target, opts \\ [])

  def snapshot(%Jido.Agent{} = agent, opts) when is_list(opts) do
    {:ok, snapshot_from_agent(agent, opts)}
  end

  def snapshot(server_or_id, opts) when is_list(opts) do
    case Jido.AgentServer.state(server_or_id) do
      {:ok, %{agent: %Jido.Agent{} = agent}} ->
        {:ok, snapshot_from_agent(agent, opts)}

      {:error, reason} ->
        {:error, Jidoka.Error.Normalize.debug_error(reason, target: server_or_id)}
    end
  end

  @doc """
  Projects a raw `Jido.Thread` without reading an agent server.

  This is useful in tests and in UI code that already has an agent snapshot.
  """
  @spec project(Thread.t() | nil, keyword()) :: %{
          context_ref: String.t(),
          thread_id: String.t() | nil,
          thread_rev: non_neg_integer(),
          entry_count: non_neg_integer(),
          llm_context: [llm_message()],
          visible_messages: [visible_message()],
          streaming_message: nil,
          events: [event()]
        }
  def project(thread, opts \\ []) when is_list(opts) do
    context_ref = context_ref(opts, nil)
    entries = thread_entries(thread)

    %{
      context_ref: context_ref,
      thread_id: thread_id(thread),
      thread_rev: thread_rev(thread),
      entry_count: length(entries),
      llm_context: llm_context(entries, context_ref, opts),
      visible_messages: visible_messages(entries, context_ref),
      streaming_message: nil,
      events: events(entries, context_ref)
    }
  end

  defp snapshot_from_agent(%Jido.Agent{} = agent, opts) do
    context_ref = context_ref(opts, agent)
    thread = ThreadAgent.get(agent)
    entries = thread_entries(thread)

    %{
      kind: :agent_view,
      agent_id: Map.get(agent, :id),
      agent_name: Map.get(agent, :name),
      context_ref: context_ref,
      thread_id: thread_id(thread),
      thread_rev: thread_rev(thread),
      entry_count: length(entries),
      llm_context: llm_context(entries, context_ref, opts),
      visible_messages: visible_messages(entries, context_ref),
      streaming_message: streaming_message(agent),
      events: events(entries, context_ref)
    }
  end

  defp context_ref(opts, agent) do
    opts[:context_ref] ||
      strategy_context_ref(agent) ||
      @default_context_ref
  end

  defp strategy_context_ref(%Jido.Agent{state: state}) when is_map(state) do
    case Map.get(state, :active_context_ref) || get_in(state, [:__strategy__, :active_context_ref]) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp strategy_context_ref(_agent), do: nil

  defp streaming_message(%Jido.Agent{state: state}) when is_map(state) do
    strategy = strategy_state(state)
    status = strategy_value(state, strategy, :status)
    active_request_id = normalize_text(strategy_value(state, strategy, :active_request_id))
    streaming_text = normalize_text(strategy_value(state, strategy, :streaming_text))
    streaming_thinking = normalize_text(strategy_value(state, strategy, :streaming_thinking))

    cond do
      status not in [:awaiting_llm, :awaiting_tool] ->
        nil

      active_request_id == "" ->
        nil

      streaming_text == "" and streaming_thinking == "" ->
        nil

      true ->
        %{
          id: "streaming-" <> active_request_id,
          seq: -1,
          role: :assistant,
          content: streaming_content(streaming_text, streaming_thinking),
          request_id: active_request_id,
          run_id: active_request_id,
          streaming?: true
        }
        |> maybe_put(:thinking, streaming_thinking)
    end
  end

  defp strategy_state(state) when is_map(state) do
    case fetch(state, :__strategy__) do
      strategy when is_map(strategy) -> strategy
      _ -> %{}
    end
  end

  defp strategy_value(state, strategy, key) do
    case fetch(strategy, key) do
      nil -> fetch(state, key)
      value -> value
    end
  end

  defp streaming_content("", thinking) when is_binary(thinking) and thinking != "", do: "Thinking..."
  defp streaming_content(content, _thinking), do: content

  defp thread_entries(%Thread{} = thread), do: Thread.to_list(thread)
  defp thread_entries(_thread), do: []

  defp thread_id(%Thread{id: id}), do: id
  defp thread_id(_thread), do: nil

  defp thread_rev(%Thread{rev: rev}) when is_integer(rev), do: rev
  defp thread_rev(_thread), do: 0

  defp llm_context(entries, context_ref, opts) do
    entries
    |> Enum.filter(&ai_message_for_context?(&1, context_ref))
    |> Enum.map(&llm_message(&1, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp visible_messages(entries, context_ref) do
    entries
    |> Enum.filter(&ai_message_for_context?(&1, context_ref))
    |> Enum.map(&visible_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp events(entries, context_ref) do
    entries
    |> Enum.filter(&event_for_context?(&1, context_ref))
    |> Enum.flat_map(&entry_events/1)
  end

  defp ai_message_for_context?(entry, context_ref) do
    entry_kind(entry) == :ai_message and payload_context_ref(entry_payload(entry)) == context_ref
  end

  defp event_for_context?(entry, context_ref) do
    case entry_kind(entry) do
      :ai_message -> payload_context_ref(entry_payload(entry)) == context_ref
      :ai_context_operation -> payload_context_ref(entry_payload(entry)) == context_ref
      _ -> false
    end
  end

  defp llm_message(entry, opts) do
    payload = entry_payload(entry)

    case normalize_role(fetch(payload, :role)) do
      :user ->
        base_message(entry, payload, :user)

      :assistant ->
        message =
          entry
          |> base_message(payload, :assistant)
          |> maybe_put(:tool_calls, normalize_optional_list(fetch(payload, :tool_calls)))

        if Keyword.get(opts, :include_private, false) do
          maybe_put(message, :thinking, normalize_text(fetch(payload, :thinking)))
        else
          message
        end

      :tool ->
        entry
        |> base_message(payload, :tool)
        |> maybe_put(:tool_call_id, normalize_text(fetch(payload, :tool_call_id)))
        |> maybe_put(:name, normalize_text(fetch(payload, :name)))

      _ ->
        nil
    end
  end

  defp visible_message(entry) do
    payload = entry_payload(entry)
    role = normalize_role(fetch(payload, :role))
    content = normalize_text(fetch(payload, :content))

    cond do
      role == :user and content != "" ->
        visible_message(entry, payload, :user, content)

      role == :assistant and content != "" ->
        visible_message(entry, payload, :assistant, content)

      true ->
        nil
    end
  end

  defp visible_message(entry, payload, role, content) do
    %{
      id: entry_id(entry),
      seq: entry_seq(entry),
      role: role,
      content: content,
      request_id: normalize_text(fetch(payload, :request_id)),
      run_id: normalize_text(fetch(payload, :run_id))
    }
  end

  defp base_message(entry, payload, role) do
    %{
      id: entry_id(entry),
      seq: entry_seq(entry),
      role: role,
      content: normalize_text(fetch(payload, :content)),
      context_ref: payload_context_ref(payload),
      request_id: normalize_text(fetch(payload, :request_id)),
      run_id: normalize_text(fetch(payload, :run_id))
    }
  end

  defp entry_events(entry) do
    payload = entry_payload(entry)

    case entry_kind(entry) do
      :ai_message ->
        message_events(entry, payload)

      :ai_context_operation ->
        [
          %{
            id: entry_id(entry),
            seq: entry_seq(entry),
            kind: :context_operation,
            label: "context operation",
            payload: debug_payload(payload),
            refs: debug_payload(entry_refs(entry))
          }
        ]

      _ ->
        []
    end
  end

  defp message_events(entry, payload) do
    case normalize_role(fetch(payload, :role)) do
      :assistant ->
        payload
        |> fetch(:tool_calls)
        |> normalize_optional_list()
        |> Enum.map(fn tool_call ->
          %{
            id: entry_id(entry),
            seq: entry_seq(entry),
            kind: :tool_call,
            label: tool_call_label(tool_call),
            payload: debug_payload(normalize_map(tool_call)),
            refs: debug_payload(entry_refs(entry))
          }
        end)

      :tool ->
        [
          %{
            id: entry_id(entry),
            seq: entry_seq(entry),
            kind: :tool_result,
            label: tool_result_label(payload),
            payload: debug_payload(payload),
            refs: debug_payload(entry_refs(entry))
          }
        ]

      _ ->
        []
    end
  end

  defp tool_call_label(tool_call) do
    case fetch(tool_call, :name) do
      name when is_binary(name) and name != "" -> "tool call: #{name}"
      _ -> "tool call"
    end
  end

  defp tool_result_label(payload) do
    case fetch(payload, :name) do
      name when is_binary(name) and name != "" -> "tool result: #{name}"
      _ -> "tool result"
    end
  end

  defp payload_context_ref(payload) do
    case fetch(payload, :context_ref) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> @default_context_ref
    end
  end

  defp entry_kind(%{kind: kind}) when is_atom(kind), do: kind
  defp entry_kind(%{"kind" => kind}) when is_atom(kind), do: kind
  defp entry_kind(%{"kind" => "ai_message"}), do: :ai_message
  defp entry_kind(%{"kind" => "ai_context_operation"}), do: :ai_context_operation
  defp entry_kind(_entry), do: nil

  defp entry_payload(%{payload: payload}) when is_map(payload), do: payload
  defp entry_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp entry_payload(_entry), do: %{}

  defp entry_refs(%{refs: refs}) when is_map(refs), do: refs
  defp entry_refs(%{"refs" => refs}) when is_map(refs), do: refs
  defp entry_refs(_entry), do: %{}

  defp entry_id(%{id: id}) when is_binary(id), do: id
  defp entry_id(%{"id" => id}) when is_binary(id), do: id
  defp entry_id(_entry), do: nil

  defp entry_seq(%{seq: seq}) when is_integer(seq), do: seq
  defp entry_seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp entry_seq(_entry), do: 0

  defp normalize_role(role) when role in [:user, :assistant, :tool], do: role
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("tool"), do: :tool
  defp normalize_role(_role), do: :unknown

  defp normalize_optional_list(value) when is_list(value), do: value
  defp normalize_optional_list(_value), do: []

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_value), do: %{}

  defp normalize_text(nil), do: ""

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(other), do: normalize_text(inspect(other))

  defp debug_payload(%{} = payload) do
    payload
    |> Jidoka.Sanitize.payload()
    |> preview_payload_content(:content)
    |> preview_payload_content("content")
  end

  defp debug_payload(value), do: Jidoka.Sanitize.payload(value)

  defp preview_payload_content(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> Map.put(payload, key, Jidoka.Sanitize.preview(value, 240))
      _value -> payload
    end
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch(%{} = map, key) when is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp fetch(_value, _key), do: nil
end
