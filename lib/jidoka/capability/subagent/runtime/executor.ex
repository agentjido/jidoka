defmodule Jidoka.Subagent.Runtime.Executor do
  @moduledoc false

  alias Jido.AI.Request
  alias Jidoka.Subagent.Context

  @spec execute(map(), map(), map()) :: {:ok, term(), map()} | {:error, term(), map()}
  def execute(%{} = subagent, params, context) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, task} <- fetch_task(params),
         :ok <- ensure_depth_allowed(context) do
      child_context = Context.child_context(context, subagent.forward_context)
      delegate(subagent, task, context, child_context, started_at)
    else
      {:error, reason} ->
        {:error, reason, error_metadata(subagent, reason, context, nil, started_at)}
    end
  end

  defp delegate(
         %{target: :ephemeral} = subagent,
         task,
         _parent_context,
         child_context,
         started_at
       ) do
    child_id = generated_child_id(subagent)

    case start_child(subagent.agent, child_id) do
      {:ok, pid} ->
        try do
          subagent
          |> ask_child(pid, task, child_context, subagent.timeout)
          |> delegate_result(subagent, :ephemeral, task, child_id, child_context, started_at)
        after
          _ = Jidoka.Runtime.stop_agent(pid)
        end

      {:error, reason} ->
        reason = {:start_failed, reason}

        {:error, reason, error_metadata(subagent, reason, child_context, task, started_at, child_id)}
    end
  end

  defp delegate(
         %{target: {:peer, peer_ref}} = subagent,
         task,
         parent_context,
         child_context,
         started_at
       ) do
    with {:ok, peer_id} <- resolve_peer_id(peer_ref, parent_context),
         {:ok, pid} <- resolve_peer_pid(peer_id),
         :ok <- verify_peer_runtime(subagent.agent, pid) do
      subagent
      |> ask_child(pid, task, child_context, subagent.timeout)
      |> delegate_result(subagent, :peer, task, peer_id, child_context, started_at)
    else
      {:error, reason} ->
        child_id = Context.peer_ref_preview(peer_ref, parent_context)

        {:error, reason, error_metadata(subagent, reason, child_context, task, started_at, child_id)}
    end
  end

  defp start_child(agent_module, child_id) do
    agent_module.start_link(id: child_id)
    |> normalize_start_result()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, reason}
  end

  defp normalize_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:error, reason}), do: {:error, reason}
  defp normalize_start_result(:ignore), do: {:error, :ignore}
  defp normalize_start_result(other), do: {:error, {:invalid_start_return, other}}

  defp generated_child_id(%{name: name}) do
    unique = System.unique_integer([:positive])
    "jidoka-subagent-#{name}-#{unique}"
  end

  defp ask_child(%{agent: agent_module} = subagent, pid, task, context, timeout) do
    if jidoka_agent_module?(agent_module) do
      ask_jidoka_child(subagent, pid, task, context, timeout)
    else
      ask_compatible_child(subagent, pid, task, context, timeout)
    end
  end

  defp ask_jidoka_child(%{agent: agent_module} = subagent, pid, task, context, timeout) do
    child_opts = [context: context, timeout: timeout]

    with {:ok, prepared_opts} <-
           Jidoka.Agent.Chat.prepare_chat_opts(child_opts, child_chat_config(agent_module)),
         request_opts <-
           Keyword.merge(
             prepared_opts,
             signal_type: "ai.react.query",
             source: "/jidoka/subagent"
           ),
         {:ok, request} <- Request.create_and_send(pid, task, request_opts) do
      request
      |> await_child_request(agent_module, pid, timeout)
      |> normalize_jidoka_child_result(subagent, pid, request.id, timeout)
    else
      {:error, reason} -> {:error, {:child_error, reason}, nil, %{}}
    end
  end

  defp await_child_request(request, agent_module, pid, timeout) do
    case Request.await(request, timeout: timeout) do
      {:error, :timeout} = result ->
        cancel_child_request(agent_module, pid, request.id)
        result

      result ->
        result
    end
  end

  defp cancel_child_request(agent_module, pid, request_id) when is_binary(request_id) do
    cond do
      function_exported?(agent_module, :runtime_module, 0) ->
        agent_module.runtime_module()
        |> maybe_cancel_child_request(pid, request_id)

      true ->
        maybe_cancel_child_request(agent_module, pid, request_id)
    end
  end

  defp maybe_cancel_child_request(module, pid, request_id) when is_atom(module) do
    if function_exported?(module, :cancel, 2) do
      _ = module.cancel(pid, request_id: request_id, reason: :subagent_timeout)
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp ask_compatible_child(%{agent: agent_module} = subagent, pid, task, context, timeout) do
    task_ref = Task.async(fn -> safe_call(fn -> agent_module.chat(pid, task, context: context) end) end)

    case Task.yield(task_ref, timeout) || Task.shutdown(task_ref, :brutal_kill) do
      {:ok, {:ok, result}} ->
        normalize_direct_child_result(result, subagent)

      {:ok, {:error, reason}} ->
        {:error, {:child_error, reason}, nil, %{}}

      {:exit, reason} ->
        {:error, {:child_error, reason}, nil, %{}}

      nil ->
        {:error, {:timeout, timeout}, nil, %{}}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_jidoka_child_result({:error, :timeout}, _subagent, pid, request_id, timeout) do
    {:error, {:timeout, timeout}, request_id, child_request_meta(pid, request_id)}
  end

  defp normalize_jidoka_child_result(await_result, subagent, pid, request_id, _timeout) do
    result =
      pid
      |> Jidoka.Chat.finalize_chat_request(request_id, await_result)
      |> Jidoka.Hooks.translate_chat_result()

    case result do
      {:ok, child_result} when is_binary(child_result) ->
        {:ok, child_result, request_id, child_request_meta(pid, request_id)}

      {:ok, child_result} when is_map(child_result) and subagent.result == :structured ->
        {:ok, child_result, request_id, child_request_meta(pid, request_id)}

      {:ok, other} ->
        {:error, {:invalid_result, other}, request_id, child_request_meta(pid, request_id)}

      {:interrupt, interrupt} ->
        {:interrupt, interrupt, request_id, child_request_meta(pid, request_id)}

      {:error, reason} ->
        {:error, {:child_error, reason}, request_id, child_request_meta(pid, request_id)}
    end
  end

  defp normalize_direct_child_result({:ok, result}, _subagent) when is_binary(result),
    do: {:ok, result, nil, %{}}

  defp normalize_direct_child_result({:ok, result}, %{result: :structured}) when is_map(result),
    do: {:ok, result, nil, %{}}

  defp normalize_direct_child_result({:ok, other}, _subagent),
    do: {:error, {:invalid_result, other}, nil, %{}}

  defp normalize_direct_child_result({:interrupt, interrupt}, _subagent) do
    case normalize_interrupt(interrupt) do
      {:ok, normalized} -> {:interrupt, normalized, nil, %{}}
      {:error, reason} -> {:error, reason, nil, %{}}
    end
  end

  defp normalize_direct_child_result({:error, reason}, _subagent),
    do: {:error, {:child_error, reason}, nil, %{}}

  defp normalize_direct_child_result(other, _subagent),
    do: {:error, {:child_error, other}, nil, %{}}

  defp normalize_interrupt(interrupt) do
    {:ok, Jidoka.Interrupt.new(interrupt)}
  rescue
    _error -> {:error, {:invalid_result, {:interrupt, interrupt}}}
  end

  defp delegate_result(
         {:ok, result, child_request_id, child_result_meta},
         subagent,
         mode,
         task,
         child_id,
         context,
         started_at
       ) do
    {:ok, result,
     call_metadata(
       subagent,
       mode,
       task,
       child_id,
       child_request_id,
       child_result_meta,
       started_at,
       :ok,
       context,
       result
     )}
  end

  defp delegate_result(
         {:error, reason, child_request_id, child_result_meta},
         subagent,
         mode,
         task,
         child_id,
         context,
         started_at
       ) do
    {:error, reason,
     call_metadata(
       subagent,
       mode,
       task,
       child_id,
       child_request_id,
       child_result_meta,
       started_at,
       {:error, reason},
       context,
       nil
     )}
  end

  defp delegate_result(
         {:interrupt, interrupt, child_request_id, child_result_meta},
         subagent,
         mode,
         task,
         child_id,
         context,
         started_at
       ) do
    case normalize_interrupt(interrupt) do
      {:ok, interrupt} ->
        reason = {:child_interrupt, interrupt}

        {:error, reason,
         call_metadata(
           subagent,
           mode,
           task,
           child_id,
           child_request_id,
           child_result_meta,
           started_at,
           {:interrupt, interrupt},
           context,
           nil
         )}

      {:error, reason} ->
        delegate_result(
          {:error, reason, child_request_id, child_result_meta},
          subagent,
          mode,
          task,
          child_id,
          context,
          started_at
        )
    end
  end

  defp child_chat_config(agent_module) do
    default_context =
      if function_exported?(agent_module, :context, 0) do
        agent_module.context()
      else
        %{}
      end

    context_schema =
      if function_exported?(agent_module, :context_schema, 0) do
        agent_module.context_schema()
      else
        nil
      end

    ash =
      cond do
        function_exported?(agent_module, :ash_domain, 0) and
            function_exported?(agent_module, :requires_actor?, 0) ->
          case agent_module.ash_domain() do
            nil -> nil
            domain -> %{domain: domain, require_actor?: agent_module.requires_actor?()}
          end

        true ->
          nil
      end

    %{context: default_context, context_schema: context_schema}
    |> maybe_put_ash(ash)
  end

  defp maybe_put_ash(config, nil), do: config
  defp maybe_put_ash(config, ash), do: Map.put(config, :ash, ash)

  defp jidoka_agent_module?(agent_module) do
    function_exported?(agent_module, :instructions, 0) and
      function_exported?(agent_module, :context, 0) and
      function_exported?(agent_module, :requires_actor?, 0)
  end

  defp child_request_meta(pid, request_id) do
    case Jido.AgentServer.state(pid) do
      {:ok, %{agent: agent}} ->
        case Request.get_request(agent, request_id) do
          nil -> %{}
          request -> %{meta: Map.get(request, :meta, %{}), status: request.status}
        end

      _ ->
        %{}
    end
  end

  defp resolve_peer_id(peer_id, _context) when is_binary(peer_id), do: {:ok, peer_id}

  defp resolve_peer_id({:context, key}, context) when is_atom(key) or is_binary(key) do
    case Context.context_value(context, key) do
      peer_id when is_binary(peer_id) and peer_id != "" -> {:ok, peer_id}
      _ -> {:error, {:peer_not_found, {:context, key}}}
    end
  end

  defp resolve_peer_pid(peer_id) when is_binary(peer_id) do
    case Jidoka.Runtime.whereis(peer_id) do
      nil -> {:error, {:peer_not_found, peer_id}}
      pid -> {:ok, pid}
    end
  end

  defp verify_peer_runtime(agent_module, pid) do
    expected_runtime = agent_module.runtime_module()

    case Jido.AgentServer.state(pid) do
      {:ok, %{agent_module: ^expected_runtime}} ->
        :ok

      {:ok, %{agent_module: other}} ->
        {:error, {:peer_mismatch, expected_runtime, other}}

      {:error, reason} ->
        {:error, {:peer_mismatch, expected_runtime, reason}}
    end
  end

  defp fetch_task(%{task: task}) when is_binary(task) do
    case String.trim(task) do
      "" -> {:error, {:invalid_task, :expected_non_empty_string}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_task(%{"task" => task}) when is_binary(task) do
    case String.trim(task) do
      "" -> {:error, {:invalid_task, :expected_non_empty_string}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_task(_params), do: {:error, {:invalid_task, :expected_non_empty_string}}

  defp ensure_depth_allowed(context) do
    if Context.current_depth(context) >= 1 do
      {:error, {:recursion_limit, 1}}
    else
      :ok
    end
  end

  defp call_metadata(
         subagent,
         mode,
         task,
         child_id,
         child_request_id,
         child_result_meta,
         started_at,
         outcome,
         context,
         result
       ) do
    %{
      sequence: next_sequence(),
      name: subagent.name,
      agent: subagent.agent,
      mode: mode,
      target: subagent.target,
      task_preview: task_preview(task),
      child_id: child_id,
      child_request_id: child_request_id,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      outcome: outcome,
      result_preview: result_preview(result),
      context_keys: Context.context_keys(context),
      child_result_meta: child_result_meta
    }
  end

  defp error_metadata(
         subagent,
         reason,
         context,
         task,
         started_at,
         child_id \\ nil,
         child_result_meta \\ %{}
       ) do
    %{
      sequence: next_sequence(),
      name: subagent.name,
      agent: subagent.agent,
      mode: target_mode(subagent.target),
      target: subagent.target,
      task_preview: task_preview(task),
      child_id: child_id,
      child_request_id: nil,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      outcome: {:error, reason},
      result_preview: nil,
      context_keys: Context.context_keys(context),
      child_result_meta: child_result_meta
    }
  end

  defp target_mode(:ephemeral), do: :ephemeral
  defp target_mode({:peer, _}), do: :peer

  defp task_preview(task) when is_binary(task) do
    task
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp task_preview(_task), do: nil

  defp result_preview(result) when is_binary(result) do
    result
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp result_preview(nil), do: nil
  defp result_preview(result), do: Jidoka.Sanitize.preview(result, 140)

  defp next_sequence, do: System.unique_integer([:positive, :monotonic])
end
