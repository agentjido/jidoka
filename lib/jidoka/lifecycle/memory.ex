defmodule Jidoka.Memory do
  @moduledoc false

  require Logger

  alias Jido.AI.Request
  alias Jidoka.Lifecycle.PhaseSpec

  @memory_context_key :__jidoka_memory__

  @type namespace_mode :: :per_agent | {:shared, String.t()} | {:context, atom() | String.t()}
  @type capture_mode :: :conversation | :off
  @type inject_mode :: :instructions | :context
  @type config :: %{
          mode: :conversation,
          namespace: namespace_mode(),
          capture: capture_mode(),
          retrieve: %{limit: pos_integer()},
          inject: inject_mode()
        }

  @spec context_key() :: atom()
  def context_key, do: @memory_context_key

  @spec default_config() :: config()
  def default_config, do: Jidoka.Memory.Config.default_config()

  @spec enabled?(config() | nil) :: boolean()
  def enabled?(nil), do: false
  def enabled?(%{}), do: true

  @spec requires_request_transformer?(config() | nil) :: boolean()
  def requires_request_transformer?(%{inject: :instructions}), do: true
  def requires_request_transformer?(_), do: false

  @spec prompt_text(map()) :: String.t() | nil
  def prompt_text(runtime_context) when is_map(runtime_context) do
    runtime_context
    |> Map.get(@memory_context_key, %{})
    |> Map.get(:prompt)
    |> case do
      prompt when is_binary(prompt) and prompt != "" -> prompt
      _ -> nil
    end
  end

  @spec normalize_imported(nil | map()) :: {:ok, config() | nil} | {:error, String.t()}
  def normalize_imported(memory), do: Jidoka.Memory.Config.normalize_imported(memory)

  @spec default_plugins(config() | nil) :: map()
  def default_plugins(config), do: Jidoka.Memory.Config.default_plugins(config)

  @spec on_before_cmd(Jido.Agent.t(), term(), config() | nil, map()) ::
          {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, action, nil, _default_context), do: {:ok, agent, action}

  def on_before_cmd(
        agent,
        {:ai_react_start, %{query: query} = params},
        %{} = config,
        default_context
      ) do
    request_id = params[:request_id] || agent.state[:last_request_id]
    params = merge_default_context(params, default_context)
    context = Map.get(params, :tool_context, %{}) || %{}

    with {:ok, namespace} <- resolve_namespace(agent, context, config),
         {:ok, records} <- retrieve_records(agent, namespace, config),
         context <- attach_memory(context, namespace, records, config),
         params <- params |> Map.put(:tool_context, context) |> Map.put(:runtime_context, context),
         agent <-
           put_request_memory_meta(
             agent,
             request_id,
             build_request_meta(config, namespace, records, query, context)
           ) do
      trace_memory(agent, request_id, :retrieve, %{
        namespace: namespace,
        record_count: length(records),
        inject: config.inject,
        capture: config.capture,
        context_keys: context_keys(context),
        context: context
      })

      {:ok, agent, {:ai_react_start, params}}
    else
      {:error, reason} when is_binary(request_id) ->
        error = memory_error(:retrieve, reason, agent, request_id, config)
        Logger.warning("Jidoka memory retrieval failed: #{Jidoka.Error.format(error)}")

        trace_memory(agent, request_id, :error, %{phase: :retrieve, error: Jidoka.Error.format(error), context: context})

        failed_agent =
          agent
          |> Request.fail_request(request_id, error)
          |> put_request_memory_meta(request_id, %{error: error, warning: Jidoka.Error.format(error)})

        {:ok, failed_agent,
         {:ai_react_request_error, %{request_id: request_id, reason: :memory_failed, message: query}}}

      {:error, reason} ->
        error = memory_error(:retrieve, reason, agent, request_id, config)
        Logger.warning("Jidoka memory retrieval failed: #{Jidoka.Error.format(error)}")

        trace_memory(agent, request_id, :error, %{phase: :retrieve, error: Jidoka.Error.format(error), context: context})

        {:ok, agent, {:ai_react_request_error, %{request_id: request_id, reason: :memory_failed, message: query}}}
    end
  end

  def on_before_cmd(agent, action, _config, _default_context), do: {:ok, agent, action}

  @doc false
  @spec before_phase_specs(config() | nil, map()) :: [PhaseSpec.t()]
  def before_phase_specs(config, default_context) when is_map(default_context) do
    [
      PhaseSpec.before(:memory_before, :memory, fn agent, action ->
        on_before_cmd(agent, action, config, default_context)
      end)
    ]
  end

  @spec on_after_cmd(Jido.Agent.t(), term(), [term()], config() | nil) ::
          {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, _action, directives, nil), do: {:ok, agent, directives}

  def on_after_cmd(agent, {:ai_react_start, %{request_id: request_id}}, directives, %{} = config)
      when is_binary(request_id) do
    case get_request_memory_meta(agent, request_id) do
      %{captured?: true} ->
        {:ok, agent, directives}

      %{error: _reason} ->
        {:ok, agent, directives}

      %{} = meta ->
        capture_conversation(agent, request_id, directives, config, meta)

      _ ->
        {:ok, agent, directives}
    end
  end

  def on_after_cmd(agent, _action, directives, _config), do: {:ok, agent, directives}

  @doc false
  @spec after_phase_specs(config() | nil) :: [PhaseSpec.t()]
  def after_phase_specs(config) do
    [
      PhaseSpec.after_phase(:memory_after, :memory, fn agent, action, directives ->
        on_after_cmd(agent, action, directives, config)
      end)
    ]
  end

  defp capture_conversation(agent, request_id, directives, %{capture: :off}, meta) do
    trace_memory(agent, request_id, :capture, %{
      namespace: meta.namespace,
      captured?: false,
      reason: :off,
      context: meta.context
    })

    {:ok, put_request_memory_meta(agent, request_id, Map.put(meta, :captured?, false)), directives}
  end

  defp capture_conversation(
         agent,
         request_id,
         directives,
         %{capture: :conversation} = config,
         meta
       ) do
    case Request.get_result(agent, request_id) do
      {:ok, result} ->
        with :ok <- remember_turn(agent, meta.namespace, user_record(meta, request_id)),
             :ok <-
               remember_turn(
                 agent,
                 meta.namespace,
                 assistant_record(agent, meta, request_id, result)
               ) do
          trace_memory(agent, request_id, :capture, %{namespace: meta.namespace, captured?: true, context: meta.context})

          {:ok, put_request_memory_meta(agent, request_id, Map.put(meta, :captured?, true)), directives}
        else
          {:error, reason} ->
            error = memory_error(:capture, reason, agent, request_id, config)
            Logger.warning("Jidoka memory capture failed: #{Jidoka.Error.format(error)}")

            trace_memory(agent, request_id, :error, %{
              phase: :capture,
              namespace: meta.namespace,
              captured?: false,
              error: Jidoka.Error.format(error),
              context: meta.context
            })

            {:ok,
             put_request_memory_meta(
               agent,
               request_id,
               meta
               |> Map.put(:captured?, false)
               |> Map.put(:capture_error, error)
               |> Map.put(:capture_warning, Jidoka.Error.format(error))
             ), directives}
        end

      _ ->
        {:ok, agent, directives}
    end
  end

  defp merge_default_context(params, default_context)
       when is_map(params) and is_map(default_context) do
    context =
      default_context
      |> Jidoka.Context.merge(Map.get(params, :tool_context, %{}) || %{})

    params
    |> Map.put(:tool_context, context)
    |> Map.put(:runtime_context, context)
  end

  defp resolve_namespace(agent, _context, %{namespace: :per_agent}) do
    with %{} = plugin_state <- Map.get(agent.state, plugin_state_key(), %{}),
         namespace when is_binary(namespace) <- Map.get(plugin_state, :namespace) do
      {:ok, namespace}
    else
      _ -> {:error, :namespace_required}
    end
  end

  defp resolve_namespace(agent, _context, %{namespace: {:shared, shared_namespace}}) do
    if is_binary(shared_namespace) and shared_namespace != "" do
      {:ok, "shared:" <> shared_namespace}
    else
      resolve_namespace(agent, %{}, %{namespace: :per_agent})
    end
  end

  defp resolve_namespace(agent, context, %{namespace: {:context, key}}) do
    case get_value(context, key) do
      nil ->
        {:error, Jidoka.Error.missing_context(key, value: context)}

      value ->
        {:ok,
         "agent:" <>
           namespace_agent_key(agent) <>
           ":context:" <> namespace_key(key) <> ":" <> namespace_value(value)}
    end
  end

  defp memory_error(phase, reason, agent, request_id, config) do
    Jidoka.Error.Normalize.memory_error(phase, reason,
      agent_id: Map.get(agent, :id),
      request_id: request_id,
      target: config[:namespace]
    )
  end

  defp retrieve_records(agent, namespace, %{retrieve: %{limit: limit}}) do
    case Jido.Memory.Runtime.retrieve(
           agent,
           %{
             namespace: namespace,
             classes: [:episodic],
             kinds: [:user_turn, :assistant_turn],
             limit: limit,
             order: :desc
           },
           memory_runtime_opts(agent, namespace)
         ) do
      {:ok, result} ->
        {:ok,
         result.hits
         |> Enum.map(& &1.record)
         |> Enum.sort_by(&record_sort_key/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attach_memory(context, namespace, records, config) do
    memory_payload = %{
      namespace: namespace,
      records: records,
      prompt: prompt_for_records(records),
      inject: config.inject
    }

    context =
      context
      |> Map.put(@memory_context_key, memory_payload)
      |> maybe_put_public_memory(memory_payload, config)

    context
  end

  defp maybe_put_public_memory(context, payload, %{inject: :context}) do
    Map.put(context, :memory, %{namespace: payload.namespace, records: payload.records})
  end

  defp maybe_put_public_memory(context, _payload, _config), do: context

  defp build_request_meta(config, namespace, records, message, context) do
    %{
      config: config,
      namespace: namespace,
      records: Jidoka.Sanitize.payload(records),
      message: message,
      context: safe_request_context(context),
      captured?: false
    }
  end

  defp prompt_for_records([]), do: nil

  defp prompt_for_records(records) do
    lines =
      records
      |> Enum.map(&record_prompt_line/1)
      |> Enum.reject(&is_nil/1)

    if lines == [] do
      nil
    else
      Enum.join(["Relevant memory:" | lines], "\n")
    end
  end

  defp record_prompt_line(%{kind: kind} = record) do
    label =
      case kind do
        :user_turn -> "User"
        "user_turn" -> "User"
        :assistant_turn -> "Assistant"
        "assistant_turn" -> "Assistant"
        _ -> "Memory"
      end

    case record_text(record) do
      nil -> nil
      text -> "- #{label}: #{Jidoka.Sanitize.preview(text, 1_000)}"
    end
  end

  defp safe_request_context(context) when is_map(context) do
    context
    |> Jidoka.Context.strip_internal()
    |> Jidoka.Sanitize.payload()
  end

  defp safe_request_context(_context), do: %{}

  defp remember_turn(agent, namespace, attrs) do
    case Jido.Memory.Runtime.remember(
           agent,
           Map.put(attrs, :namespace, namespace),
           memory_runtime_opts(agent, namespace)
         ) do
      {:ok, _record} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp user_record(meta, request_id) do
    %{
      class: :episodic,
      kind: :user_turn,
      text: meta.message,
      content: %{role: "user", message: meta.message},
      tags: ["jidoka", "conversation", "user"],
      source: "/jidoka/agent",
      metadata: capture_metadata(meta.context, request_id)
    }
  end

  defp assistant_record(agent, meta, request_id, result) do
    text = record_text(result)

    %{
      class: :episodic,
      kind: :assistant_turn,
      text: text,
      content: %{role: "assistant", result: result},
      tags: ["jidoka", "conversation", "assistant"],
      source: "/jidoka/agent",
      metadata:
        capture_metadata(meta.context, request_id)
        |> Map.put(:agent, agent.name)
    }
  end

  defp capture_metadata(context, request_id) do
    %{
      turn_id: request_id
    }
    |> maybe_put_metadata(:actor, get_value(context, :actor))
    |> maybe_put_metadata(
      :session_id,
      get_value(context, :session_id, get_value(context, :session))
    )
    |> maybe_put_metadata(:tenant, get_value(context, :tenant))
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, Jidoka.Sanitize.payload(value))

  defp namespace_agent_key(%{name: name}) when is_binary(name), do: name
  defp namespace_agent_key(%{id: id}) when is_binary(id), do: id
  defp namespace_agent_key(_agent), do: "agent"

  defp namespace_key(key) when is_atom(key), do: Atom.to_string(key)
  defp namespace_key(key) when is_binary(key), do: String.trim(key)

  defp namespace_value(value) when is_binary(value), do: String.trim(value)
  defp namespace_value(value) when is_atom(value), do: Atom.to_string(value)
  defp namespace_value(value) when is_integer(value), do: Integer.to_string(value)
  defp namespace_value(value), do: inspect(value)

  defp record_text(%{text: text}) when is_binary(text) and text != "", do: text
  defp record_text(%{content: content}) when is_binary(content) and content != "", do: content

  defp record_text(%{content: %{message: message}}) when is_binary(message) and message != "",
    do: message

  defp record_text(%{content: %{result: result}}), do: record_text(result)
  defp record_text(result) when is_binary(result) and result != "", do: result
  defp record_text(nil), do: nil
  defp record_text(other), do: inspect(other)

  defp record_sort_key(record) do
    {
      Map.get(record, :observed_at, 0),
      kind_sort_rank(Map.get(record, :kind)),
      Map.get(record, :id, "")
    }
  end

  defp kind_sort_rank(:user_turn), do: 0
  defp kind_sort_rank("user_turn"), do: 0
  defp kind_sort_rank(:assistant_turn), do: 1
  defp kind_sort_rank("assistant_turn"), do: 1
  defp kind_sort_rank(_other), do: 2

  defp plugin_state_key, do: Jido.Memory.Runtime.plugin_state_key()

  defp memory_runtime_opts(_agent, namespace), do: [namespace: namespace]

  defp put_request_memory_meta(agent, request_id, memory_meta) when is_binary(request_id) do
    update_in(agent.state, [:requests, request_id], fn
      nil ->
        %{meta: %{jidoka_memory: memory_meta}}

      request ->
        meta =
          request
          |> Map.get(:meta, %{})
          |> Map.put(:jidoka_memory, memory_meta)

        Map.put(request, :meta, meta)
    end)
    |> then(&%{agent | state: &1})
  end

  defp put_request_memory_meta(agent, _request_id, _memory_meta), do: agent

  defp get_request_memory_meta(agent, request_id) when is_binary(request_id) do
    get_in(agent.state, [:requests, request_id, :meta, :jidoka_memory])
  end

  defp trace_memory(agent, request_id, event, metadata) do
    Jidoka.Trace.emit(
      :memory,
      Map.merge(
        %{
          event: event,
          request_id: request_id,
          agent_id: Map.get(agent, :id)
        },
        metadata
      )
    )
  end

  defp context_keys(context) when is_map(context) do
    context
    |> Jidoka.Context.strip_internal()
    |> Map.keys()
    |> Enum.map(&key_to_string/1)
    |> Enum.sort()
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)

  defp get_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, normalize_lookup_key(key), default))
  end

  defp normalize_lookup_key(key) when is_atom(key), do: Atom.to_string(key)

  defp normalize_lookup_key(key) when is_binary(key) do
    case safe_existing_atom(key) do
      nil -> key
      atom -> atom
    end
  end

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
