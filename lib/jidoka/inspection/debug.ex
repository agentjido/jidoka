defmodule Jidoka.Debug do
  @moduledoc false

  alias Jido.AI.Request

  @meta_key :jidoka_debug
  @pending_table :jidoka_debug_requests
  @type summary :: %{
          request_id: String.t(),
          status: atom() | nil,
          model: term(),
          input_message: String.t() | nil,
          user_message: String.t() | nil,
          system_prompt: String.t() | nil,
          prompt_preview: map() | nil,
          prompt_sections: [map()],
          skills: [String.t()],
          tool_names: [String.t()],
          operation_names: [String.t()],
          mcp_tools: [String.t()],
          mcp_errors: [map()],
          context_preview: [String.t()],
          memory: map() | nil,
          compaction: map() | nil,
          subagents: [map()],
          workflows: [map()],
          handoffs: [map()],
          usage: map() | nil,
          duration_ms: non_neg_integer() | nil,
          interrupt: map() | nil,
          error: map() | nil,
          message_count: non_neg_integer() | nil
        }

  @spec request_meta_key() :: atom()
  def request_meta_key, do: @meta_key

  @spec record_prompt_preview(map(), String.t() | nil, map()) :: :ok
  def record_prompt_preview(runtime_context, prompt, request)
      when is_map(runtime_context) and is_map(request) do
    record_runtime_meta(runtime_context, %{
      system_prompt: normalize_text(prompt),
      message_count: count_messages(request),
      tool_names: tool_names_from_request(Map.get(request, :tools))
    })
  end

  @spec record_runtime_meta(map(), map()) :: :ok
  def record_runtime_meta(runtime_context, attrs)
      when is_map(runtime_context) and is_map(attrs) do
    maybe_store_runtime_meta(runtime_context, attrs)
  end

  @spec request_summary(pid() | String.t()) :: {:ok, summary()} | {:error, term()}
  def request_summary(server_or_id) do
    with {:ok, agent, request_id, request, pending_meta, subagent_calls, workflow_calls, handoff_calls} <-
           latest_request_snapshot(server_or_id) do
      {:ok, build_summary(agent, request_id, request, pending_meta, subagent_calls, workflow_calls, handoff_calls)}
    end
  end

  @spec request_summary(Jido.Agent.t(), String.t()) :: {:ok, summary()} | {:error, term()}
  def request_summary(%Jido.Agent{} = agent, request_id) when is_binary(request_id) do
    case Request.get_request(agent, request_id) do
      nil ->
        {:error, Jidoka.Error.Normalize.debug_error(:request_not_found, request_id: request_id)}

      request ->
        {:ok,
         build_summary(
           agent,
           request_id,
           request,
           %{},
           stored_subagent_calls(agent, request_id),
           stored_workflow_calls(agent, request_id),
           stored_handoff_calls(agent, request_id)
         )}
    end
  end

  def request_summary(_server_or_agent, request_id) do
    {:error, Jidoka.Error.Normalize.debug_error(:request_not_found, request_id: request_id)}
  end

  defp latest_request_snapshot(server_or_id) do
    with {:ok, server} <- resolve_server(server_or_id) do
      latest_request_snapshot_for_server(server)
    else
      :error ->
        {:error, Jidoka.Error.Normalize.debug_error(:not_found, target: server_or_id)}
    end
  end

  defp latest_request_snapshot_for_server(server) do
    case Jido.AgentServer.state(server) do
      {:ok, %{agent: agent}} ->
        request_id = agent.state[:last_request_id]

        case Request.get_request(agent, request_id) do
          nil ->
            {:error, Jidoka.Error.Normalize.debug_error(:request_not_found, request_id: request_id)}

          request ->
            pending_meta = pending_runtime_meta(server, request_id)
            subagent_calls = Jidoka.Subagent.request_calls(server, request_id)
            workflow_calls = Jidoka.Workflow.Capability.request_calls(server, request_id)
            handoff_calls = Jidoka.Handoff.Capability.request_calls(server, request_id)
            {:ok, agent, request_id, request, pending_meta, subagent_calls, workflow_calls, handoff_calls}
        end

      {:error, reason} ->
        {:error, Jidoka.Error.Normalize.debug_error(reason)}
    end
  end

  defp build_summary(agent, request_id, request, pending_meta, subagent_calls, workflow_calls, handoff_calls) do
    request_meta = Map.get(request, :meta, %{})
    debug_meta = Map.merge(Map.get(request_meta, @meta_key, %{}), pending_meta)
    hook_meta = Map.get(request_meta, :jidoka_hooks, %{})
    guardrail_meta = Map.get(request_meta, :jidoka_guardrails, %{})
    memory_meta = Map.get(request_meta, :jidoka_memory, %{})
    compaction_meta = Map.get(request_meta, :jidoka_compaction, %{})
    user_message = normalize_text(request_message(request, hook_meta, guardrail_meta))
    system_prompt = normalize_text(system_prompt(debug_meta, agent))
    tool_names = effective_tool_names(agent, debug_meta, hook_meta, guardrail_meta)
    message_count = Map.get(debug_meta, :message_count)

    interrupt =
      case request.error do
        {:interrupt, %Jidoka.Interrupt{} = interrupt} -> interrupt
        _ -> Map.get(guardrail_meta, :interrupt) || Map.get(hook_meta, :interrupt)
      end

    %{
      request_id: request_id,
      status: Map.get(request, :status),
      model: resolved_model(agent),
      input_message: text_preview(normalize_text(Map.get(request, :query))),
      user_message: text_preview(user_message),
      system_prompt: text_preview(system_prompt),
      prompt_preview: prompt_preview(system_prompt, user_message, message_count, tool_names),
      prompt_sections: prompt_sections(debug_meta),
      skills: normalize_string_list(debug_meta[:skills]),
      tool_names: tool_names,
      operation_names: tool_names,
      mcp_tools: normalize_string_list(debug_meta[:mcp_tools]),
      mcp_errors: normalize_mcp_errors(debug_meta[:mcp_errors]),
      context_preview: context_preview(hook_meta, guardrail_meta, memory_meta),
      memory: memory_summary(memory_meta),
      compaction: compaction_summary(compaction_meta),
      subagents: subagent_calls,
      workflows: workflow_calls,
      handoffs: handoff_calls,
      usage: usage_summary(Map.get(request_meta, :usage)),
      duration_ms: duration_ms(request),
      interrupt: interrupt_summary(interrupt),
      error: error_summary(request.error),
      message_count: message_count
    }
  end

  defp resolved_model(agent) do
    agent.state[:model] || get_in(agent.state, [:__strategy__, :config, :model])
  end

  defp request_message(request, hook_meta, guardrail_meta) do
    hook_meta[:message] ||
      guardrail_meta[:message] ||
      Map.get(request, :query)
  end

  defp system_prompt(debug_meta, agent) do
    debug_meta[:system_prompt] ||
      get_in(agent.state, [:__strategy__, :config, :system_prompt])
  end

  defp effective_tool_names(agent, debug_meta, hook_meta, guardrail_meta) do
    allowed_tools = hook_meta[:allowed_tools] || guardrail_meta[:allowed_tools]

    tool_names =
      case debug_meta[:tool_names] do
        names when is_list(names) and names != [] ->
          names

        _ ->
          case agent do
            %Jido.Agent{state: %{__strategy__: %{config: %{actions_by_name: actions}}}}
            when is_map(actions) ->
              Map.keys(actions)

            _ ->
              []
          end
      end

    tool_names =
      tool_names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()

    case allowed_tools do
      nil ->
        tool_names

      names when is_list(names) ->
        allowed =
          names
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        Enum.filter(tool_names, &MapSet.member?(allowed, &1))

      _ ->
        tool_names
    end
  end

  defp context_preview(hook_meta, guardrail_meta, memory_meta) do
    context =
      hook_meta[:context] ||
        guardrail_meta[:context] ||
        memory_meta[:context] ||
        %{}

    context
    |> Jidoka.Context.strip_internal()
    |> Map.delete(:memory)
    |> Map.delete("memory")
    |> Enum.reduce([], fn {key, value}, acc ->
      case preview_context_entry(key, value) do
        nil -> acc
        entry -> [entry | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.sort()
  end

  defp memory_summary(%{error: reason}), do: %{error: error_summary(reason)}

  defp memory_summary(%{} = memory_meta) do
    %{
      namespace: memory_meta[:namespace],
      retrieved: length(Map.get(memory_meta, :records, [])),
      inject: get_in(memory_meta, [:config, :inject]),
      captured: memory_meta[:captured?],
      capture_error: error_summary(memory_meta[:capture_error]),
      capture_warning: Jidoka.Sanitize.payload(memory_meta[:capture_warning])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Jidoka.Sanitize.payload()
  end

  defp memory_summary(_), do: nil

  defp compaction_summary(%{} = compaction_meta) do
    compaction_meta
    |> Map.take([
      :id,
      :status,
      :strategy,
      :summary_preview,
      :source_message_count,
      :retained_message_count,
      :error,
      :metadata
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
    |> Jidoka.Sanitize.payload()
    |> case do
      empty when empty == %{} -> nil
      summary -> summary
    end
  end

  defp compaction_summary(_), do: nil

  defp prompt_preview(system_prompt, user_message, message_count, tool_names) do
    %{
      system_prompt: text_preview(system_prompt),
      user_message: text_preview(user_message),
      message_count: message_count,
      tool_names: tool_names
    }
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when value == %{} -> true
      _entry -> false
    end)
    |> Map.new()
    |> case do
      empty when empty == %{} -> nil
      preview -> preview
    end
  end

  defp prompt_sections(%{prompt_sections: sections}) when is_list(sections) do
    Enum.map(sections, &Jidoka.Sanitize.payload/1)
  end

  defp prompt_sections(_debug_meta), do: []

  defp text_preview(nil), do: nil
  defp text_preview(text), do: Jidoka.Sanitize.preview(text, 240)

  defp interrupt_summary(nil), do: nil

  defp interrupt_summary(%Jidoka.Interrupt{} = interrupt) do
    %{
      id: interrupt.id,
      kind: interrupt.kind,
      message: text_preview(interrupt.message),
      data_keys: interrupt.data |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp interrupt_summary(interrupt), do: Jidoka.Sanitize.payload(interrupt)

  defp error_summary(nil), do: nil

  defp error_summary({:interrupt, %Jidoka.Interrupt{} = interrupt}) do
    %{
      category: :interrupt,
      message: text_preview(interrupt.message),
      id: interrupt.id,
      kind: interrupt.kind
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_summary(error), do: Jidoka.Error.to_map(error)

  defp usage_summary(%{} = usage) do
    %{
      input: usage[:input] || usage[:input_tokens],
      output: usage[:output] || usage[:output_tokens],
      total: usage[:total_tokens],
      cost: usage[:total_cost] || usage[:cost]
    }
  end

  defp usage_summary(_), do: nil

  defp duration_ms(%{inserted_at: inserted_at, completed_at: completed_at})
       when is_integer(inserted_at) and is_integer(completed_at) and completed_at >= inserted_at do
    completed_at - inserted_at
  end

  defp duration_ms(_request), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_string_list(_), do: []

  defp normalize_mcp_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{endpoint: endpoint, prefix: prefix, reason: reason} ->
        %{endpoint: endpoint, prefix: prefix, reason: reason, message: Jidoka.Error.format(reason)}

      %{endpoint: endpoint, prefix: prefix, message: message} ->
        %{endpoint: endpoint, prefix: prefix, reason: message, message: message}

      other ->
        %{endpoint: :unknown, prefix: nil, reason: other, message: Jidoka.Error.format(other)}
    end)
  end

  defp normalize_mcp_errors(_), do: []

  defp pending_runtime_meta(server_or_id, request_id) when is_binary(request_id) do
    case resolve_server(server_or_id) do
      {:ok, server} ->
        ensure_pending_table()

        @pending_table
        |> :ets.take({server, request_id})
        |> Enum.reduce(%{}, fn {{^server, ^request_id}, meta}, acc -> Map.merge(acc, meta) end)

      :error ->
        %{}
    end
  end

  defp maybe_store_runtime_meta(runtime_context, attrs)
       when is_map(runtime_context) and is_map(attrs) do
    case {resolve_server(Map.get(runtime_context, Jidoka.Subagent.server_key())),
          Map.get(runtime_context, Jidoka.Subagent.request_id_key())} do
      {{:ok, server}, request_id} when is_binary(request_id) ->
        ensure_pending_table()
        key = {server, request_id}

        existing =
          case :ets.lookup(@pending_table, key) do
            [{^key, current}] -> current
            _ -> %{}
          end

        :ets.insert(@pending_table, {key, Map.merge(existing, attrs)})
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_store_runtime_meta(_runtime_context, _attrs), do: :ok

  defp stored_subagent_calls(agent, request_id) do
    case Jidoka.Subagent.get_request_meta(agent, request_id) do
      %{calls: calls} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp stored_workflow_calls(agent, request_id) do
    case Jidoka.Workflow.Capability.get_request_meta(agent, request_id) do
      %{calls: calls} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp stored_handoff_calls(agent, request_id) do
    case Jidoka.Handoff.Capability.get_request_meta(agent, request_id) do
      %{calls: calls} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp resolve_server(server) when is_pid(server), do: {:ok, server}

  defp resolve_server(server_id) when is_binary(server_id) do
    case Jidoka.Runtime.whereis(server_id) || jido_registry_whereis(server_id) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end

  defp resolve_server(_), do: :error

  defp jido_registry_whereis(server_id) do
    Jido.AgentServer.whereis(Jido.Registry, server_id)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp ensure_pending_table do
    case :ets.whereis(@pending_table) do
      :undefined -> :ets.new(@pending_table, [:named_table, :public, :set])
      _table -> @pending_table
    end
  end

  defp tool_names_from_request(nil), do: []

  defp tool_names_from_request(tools) when is_map(tools) do
    tools
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp tool_names_from_request(tools) when is_list(tools) do
    tools
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp tool_names_from_request(_), do: []

  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name({name, _value}) when is_binary(name), do: name

  defp tool_name(module) when is_atom(module) do
    cond do
      function_exported?(module, :name, 0) -> module.name()
      true -> nil
    end
  end

  defp tool_name(_tool), do: nil

  defp preview_context_entry(key, value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_atom(value) do
    key = normalize_context_key(key)

    value =
      cond do
        Jidoka.Sanitize.sensitive_key?(key) -> "[REDACTED]"
        is_binary(value) -> Jidoka.Sanitize.preview(value, 120)
        true -> value
      end

    "#{key}=#{inspect(value)}"
  end

  defp preview_context_entry(_key, _value), do: nil

  defp normalize_context_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_context_key(key) when is_binary(key), do: key
  defp normalize_context_key(key), do: inspect(key)

  defp count_messages(%{messages: messages}) when is_list(messages), do: length(messages)
  defp count_messages(_request), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_text(other), do: normalize_text(inspect(other))
end
