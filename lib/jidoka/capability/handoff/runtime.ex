defmodule Jidoka.Handoff.Runtime do
  @moduledoc false

  @request_meta_key :jidoka_handoffs

  @doc false
  @spec run_handoff_tool(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run_handoff_tool(%{} = capability, params, context)
      when is_map(params) and is_map(context) do
    started_at = System.monotonic_time(:millisecond)
    trace_handoff(context, capability, :start)

    with {:ok, payload} <- normalize_payload(params),
         {:ok, conversation_id} <- conversation_id(context, capability),
         forwarded_context <- forwarded_context(context, capability.forward_context),
         {:ok, to_agent_id} <- resolve_target(capability, conversation_id, context),
         {:ok, _pid} <- ensure_target_running(capability, to_agent_id),
         :ok <- verify_peer_runtime(capability.agent, to_agent_id) do
      handoff =
        Jidoka.Handoff.new(
          conversation_id: conversation_id,
          from_agent: Map.get(context, Jidoka.Handoff.from_agent_key()),
          to_agent: capability.agent,
          to_agent_id: to_agent_id,
          name: capability.name,
          message: payload.message,
          summary: payload.summary,
          reason: payload.reason,
          context: forwarded_context,
          request_id: Map.get(context, Jidoka.Handoff.request_id_key()),
          metadata: %{
            target: capability.target,
            duration_ms: System.monotonic_time(:millisecond) - started_at
          }
        )

      Jidoka.Handoff.Registry.put_owner(conversation_id, handoff)
      metadata = call_metadata(capability, handoff, started_at, :handoff)
      maybe_record_metadata(context, metadata)
      trace_handoff(context, capability, :stop, trace_metadata(metadata))
      {:error, {:handoff, handoff}}
    else
      {:error, reason} ->
        error = normalize_handoff_error(capability, reason, context)
        metadata = error_metadata(capability, context, error, started_at)
        maybe_record_metadata(context, metadata)
        trace_handoff(context, capability, :error, trace_metadata(metadata, %{error: Jidoka.Error.format(error)}))
        {:error, error}
    end
  end

  def run_handoff_tool(%{} = capability, _params, context) do
    error = normalize_handoff_error(capability, {:invalid_payload, :expected_map}, context)
    maybe_record_metadata(context, error_metadata(capability, context, error, System.monotonic_time(:millisecond)))
    trace_handoff(context, capability, :error, %{error: Jidoka.Error.format(error)})
    {:error, error}
  end

  @doc false
  @spec on_before_cmd(Jido.Agent.t(), term()) :: {:ok, Jido.Agent.t(), term()}
  def on_before_cmd(agent, {:ai_react_start, %{request_id: request_id} = params})
      when is_binary(request_id) do
    context = Map.get(params, :tool_context, %{}) || %{}

    context =
      context
      |> Map.put(Jidoka.Handoff.request_id_key(), request_id)
      |> Map.put(Jidoka.Handoff.server_key(), self())
      |> Map.put(Jidoka.Handoff.from_agent_key(), from_agent(agent))

    {:ok, agent, {:ai_react_start, Map.put(params, :tool_context, context)}}
  end

  def on_before_cmd(agent, action), do: {:ok, agent, action}

  @doc false
  @spec on_after_cmd(Jido.Agent.t(), term(), [term()]) :: {:ok, Jido.Agent.t(), [term()]}
  def on_after_cmd(agent, action, directives) do
    case request_id_from_action(action) do
      request_id when is_binary(request_id) ->
        calls = drain_request_meta(self(), request_id)

        if calls == [] do
          {:ok, agent, directives}
        else
          {:ok, put_request_meta(agent, request_id, %{calls: calls}), directives}
        end

      _ ->
        {:ok, agent, directives}
    end
  end

  @doc false
  @spec get_request_meta(Jido.Agent.t(), String.t()) :: map() | nil
  def get_request_meta(agent, request_id) when is_binary(request_id) do
    get_in(agent.state, [:requests, request_id, :meta, @request_meta_key])
  end

  def get_request_meta(_agent, _request_id), do: nil

  @doc false
  @spec request_calls(pid() | String.t() | Jido.Agent.t(), String.t()) :: [map()]
  def request_calls(server_or_agent, request_id) when is_binary(request_id) do
    stored_calls = stored_request_calls(server_or_agent, request_id)
    pending_calls = pending_request_calls(server_or_agent, request_id)

    (stored_calls ++ pending_calls)
    |> Enum.sort_by(&Map.get(&1, :sequence, 0))
    |> Enum.uniq_by(&request_call_identity/1)
  end

  def request_calls(_server_or_agent, _request_id), do: []

  @doc false
  @spec latest_request_calls(pid() | String.t()) :: [map()]
  def latest_request_calls(server_or_id) do
    case Jido.AgentServer.state(server_or_id) do
      {:ok, %{agent: agent}} ->
        case agent.state.last_request_id do
          request_id when is_binary(request_id) -> request_calls(server_or_id, request_id)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp normalize_payload(params) do
    with {:ok, message} <- required_string(params, :message) do
      {:ok,
       %{
         message: message,
         summary: optional_string(params, :summary),
         reason: optional_string(params, :reason)
       }}
    end
  end

  defp required_string(params, key) do
    case context_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_payload, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:invalid_payload, key}}
    end
  end

  defp optional_string(params, key) do
    case context_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp conversation_id(context, %{target: :auto}) do
    case context_value(context, Jidoka.Handoff.context_key()) || context_value(context, :conversation) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_conversation}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_conversation}
    end
  end

  defp conversation_id(context, _capability) do
    case context_value(context, Jidoka.Handoff.context_key()) || context_value(context, :conversation) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:ok, nil}
    end
  end

  defp resolve_target(%{target: :auto, name: name}, conversation_id, _context) do
    {:ok, generated_agent_id(conversation_id, name)}
  end

  defp resolve_target(%{target: {:peer, peer_id}}, _conversation_id, context) do
    resolve_peer_id(peer_id, context)
  end

  defp ensure_target_running(%{target: :auto, agent: agent_module}, agent_id)
       when is_binary(agent_id) do
    case Jidoka.Runtime.whereis(agent_id) do
      nil ->
        agent_module.start_link(id: agent_id)
        |> normalize_start_result()

      pid when is_pid(pid) ->
        {:ok, pid}
    end
  end

  defp ensure_target_running(%{target: {:peer, _peer}}, agent_id)
       when is_binary(agent_id) do
    case Jidoka.Runtime.whereis(agent_id) do
      nil -> {:error, {:peer_not_found, agent_id}}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp normalize_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:error, reason}), do: {:error, {:start_failed, reason}}
  defp normalize_start_result(:ignore), do: {:error, {:start_failed, :ignore}}
  defp normalize_start_result(other), do: {:error, {:start_failed, {:invalid_start_return, other}}}

  defp trace_handoff(context, capability, event, metadata \\ %{}) do
    measurements =
      case Map.get(metadata, :duration_ms) do
        duration_ms when is_integer(duration_ms) -> %{duration_ms: duration_ms}
        _ -> %{}
      end

    Jidoka.Trace.emit(
      :handoff,
      Jidoka.Trace.correlation_refs(context)
      |> Map.merge(%{
        event: event,
        handoff: capability.name,
        name: capability.name,
        target: inspect(capability.target),
        request_id: Map.get(context, Jidoka.Handoff.request_id_key()),
        agent_id: Map.get(context, Jidoka.Trace.agent_id_key()) || Map.get(context, Jidoka.Handoff.from_agent_key()),
        conversation_id: context_value(context, Jidoka.Handoff.context_key()) || context_value(context, :conversation)
      })
      |> Map.merge(metadata),
      measurements
    )
  end

  defp trace_metadata(metadata, extra \\ %{}) when is_map(metadata) do
    metadata
    |> Map.take([
      :context_keys,
      :conversation_id,
      :duration_ms,
      :outcome,
      :reason_preview,
      :request_id,
      :summary_preview,
      :to_agent_id
    ])
    |> Map.merge(extra)
  end

  defp verify_peer_runtime(agent_module, agent_id) do
    expected_runtime = agent_module.runtime_module()

    case Jidoka.Runtime.whereis(agent_id) do
      nil ->
        {:error, {:peer_not_found, agent_id}}

      pid ->
        case Jido.AgentServer.state(pid) do
          {:ok, %{agent_module: ^expected_runtime}} -> :ok
          {:ok, %{agent_module: other}} -> {:error, {:peer_mismatch, expected_runtime, other}}
          {:error, reason} -> {:error, {:peer_mismatch, expected_runtime, reason}}
        end
    end
  end

  defp generated_agent_id(conversation_id, name) do
    slug =
      "#{conversation_id}-#{name}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")

    "jidoka_handoff_#{slug}"
  end

  defp forwarded_context(context, policy) do
    context
    |> Jidoka.Context.sanitize_for_subagent()
    |> Map.delete(:conversation)
    |> Map.delete("conversation")
    |> apply_forward_context_policy(policy)
  end

  defp maybe_record_metadata(context, metadata) when is_map(context) and is_map(metadata) do
    parent_server = Map.get(context, Jidoka.Handoff.server_key())
    request_id = Map.get(context, Jidoka.Handoff.request_id_key())

    if is_pid(parent_server) and is_binary(request_id) do
      Jidoka.Handoff.Metadata.insert(parent_server, request_id, metadata)
    end

    :ok
  end

  defp maybe_record_metadata(_context, _metadata), do: :ok

  defp request_id_from_action({_action, params}), do: request_id_from_params(params)
  defp request_id_from_action(_action), do: nil

  defp request_id_from_params(%{request_id: request_id}) when is_binary(request_id), do: request_id
  defp request_id_from_params(%{"request_id" => request_id}) when is_binary(request_id), do: request_id
  defp request_id_from_params(%{event: event}), do: request_id_from_params(event)
  defp request_id_from_params(%{"event" => event}), do: request_id_from_params(event)
  defp request_id_from_params(_params), do: nil

  defp drain_request_meta(server, request_id) when is_pid(server) and is_binary(request_id) do
    Jidoka.Handoff.Metadata.drain(server, request_id)
  end

  defp drain_request_meta(_server, _request_id), do: []

  defp lookup_request_meta(server, request_id) when is_pid(server) and is_binary(request_id) do
    Jidoka.Handoff.Metadata.lookup(server, request_id)
  end

  defp lookup_request_meta(_server, _request_id), do: []

  defp put_request_meta(agent, request_id, %{calls: calls}) do
    state =
      update_in(agent.state, [:requests, request_id], fn
        nil ->
          nil

        request ->
          existing_calls = get_in(request, [:meta, @request_meta_key, :calls]) || []

          request
          |> Map.put(
            :meta,
            Map.merge(
              Map.get(request, :meta, %{}),
              %{@request_meta_key => %{calls: existing_calls ++ calls}}
            )
          )
      end)

    %{agent | state: state}
  end

  defp call_metadata(capability, %Jidoka.Handoff{} = handoff, started_at, outcome) do
    %{
      sequence: next_sequence(),
      name: capability.name,
      agent: capability.agent,
      target: capability.target,
      to_agent_id: handoff.to_agent_id,
      conversation_id: handoff.conversation_id,
      request_id: handoff.request_id,
      handoff: handoff,
      message_preview: text_preview(handoff.message),
      summary_preview: text_preview(handoff.summary),
      reason_preview: text_preview(handoff.reason),
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      outcome: outcome,
      context_keys: context_keys(handoff.context)
    }
  end

  defp error_metadata(capability, context, error, started_at) do
    %{
      sequence: next_sequence(),
      name: capability.name,
      agent: capability.agent,
      target: capability.target,
      to_agent_id: nil,
      conversation_id: context_value(context, Jidoka.Handoff.context_key()),
      request_id: Map.get(context, Jidoka.Handoff.request_id_key()),
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      outcome: {:error, error},
      context_keys: context_keys(context)
    }
  end

  defp normalize_handoff_error(capability, reason, context) do
    Jidoka.Error.Normalize.handoff_error(reason,
      agent_id: Map.get(context, Jidoka.Handoff.from_agent_key()),
      target: capability.target,
      field: :handoff,
      request_id: Map.get(context, Jidoka.Handoff.request_id_key()),
      cause: reason
    )
  end

  defp stored_request_calls(%Jido.Agent{} = agent, request_id) do
    case get_request_meta(agent, request_id) do
      %{calls: calls} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp stored_request_calls(server_or_id, request_id) do
    try do
      case Jido.AgentServer.state(server_or_id) do
        {:ok, %{agent: agent}} -> stored_request_calls(agent, request_id)
        _ -> []
      end
    catch
      :exit, _reason -> []
    end
  end

  defp pending_request_calls(server, request_id) when is_pid(server), do: lookup_request_meta(server, request_id)

  defp pending_request_calls(server_id, request_id) when is_binary(server_id) do
    case Jidoka.Runtime.whereis(server_id) do
      nil -> []
      pid -> lookup_request_meta(pid, request_id)
    end
  end

  defp pending_request_calls(_server_or_agent, _request_id), do: []

  defp request_call_identity(%{sequence: sequence}) when is_integer(sequence), do: {:sequence, sequence}

  defp request_call_identity(call) when is_map(call) do
    {:fallback, Map.get(call, :name), Map.get(call, :request_id), Map.get(call, :to_agent_id)}
  end

  defp resolve_peer_id(peer_id, _context) when is_binary(peer_id), do: {:ok, peer_id}

  defp resolve_peer_id({:context, key}, context) when is_atom(key) or is_binary(key) do
    case context_value(context, key) do
      peer_id when is_binary(peer_id) and peer_id != "" -> {:ok, peer_id}
      _ -> {:error, {:peer_not_found, {:context, key}}}
    end
  end

  defp apply_forward_context_policy(context, :public), do: context
  defp apply_forward_context_policy(_context, :none), do: %{}

  defp apply_forward_context_policy(context, {:only, keys}) when is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_equivalent_key(context, key) do
        {:ok, actual_key, value} -> Map.put(acc, actual_key, value)
        :error -> acc
      end
    end)
  end

  defp apply_forward_context_policy(context, {:except, keys}) when is_list(keys) do
    Enum.reduce(keys, context, fn key, acc ->
      case fetch_equivalent_key(acc, key) do
        {:ok, actual_key, _value} -> Map.delete(acc, actual_key)
        :error -> acc
      end
    end)
  end

  defp context_value(context, key) when is_map(context) do
    case fetch_equivalent_key(context, key) do
      {:ok, _actual_key, value} -> value
      :error -> nil
    end
  end

  defp fetch_equivalent_key(context, key) when is_map(context) do
    Enum.find_value(context, :error, fn {existing_key, value} ->
      if equivalent_key?(existing_key, key) do
        {:ok, existing_key, value}
      end
    end)
  end

  defp equivalent_key?(left, right), do: key_to_string(left) == key_to_string(right)
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)

  defp context_keys(context) when is_map(context) do
    context
    |> Jidoka.Context.strip_internal()
    |> Map.keys()
    |> Enum.map(&key_to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp text_preview(nil), do: nil

  defp text_preview(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp from_agent(agent) do
    Map.get(agent, :name) || Map.get(agent, :id)
  end

  defp next_sequence, do: System.unique_integer([:positive, :monotonic])
end
