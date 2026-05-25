defmodule Jidoka.Workflow.Capability.Runtime do
  @moduledoc false

  @request_meta_key :jidoka_workflows

  @doc false
  @spec run_workflow_tool(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run_workflow_tool(%{} = workflow, params, context)
      when is_map(params) and is_map(context) do
    started_at = System.monotonic_time(:millisecond)
    workflow_context = forwarded_context(context, workflow.forward_context)

    trace_workflow(context, workflow, :start, %{
      input_keys: map_keys(params),
      context_keys: context_keys(workflow_context)
    })

    case Jidoka.Workflow.run(workflow.workflow, params,
           context: workflow_context,
           timeout: workflow.timeout,
           return: :debug
         ) do
      {:ok, %{output: output} = debug} ->
        trace_workflow_steps(context, workflow, debug)
        metadata = call_metadata(workflow, params, workflow_context, started_at, :ok, output)
        maybe_record_metadata(context, metadata)

        trace_workflow(
          context,
          workflow,
          :stop,
          Map.take(metadata, [:duration_ms, :input_keys, :context_keys, :output_preview])
        )

        {:ok, visible_result(workflow, output, metadata)}

      {:error, reason} ->
        error = normalize_workflow_error(workflow, reason, context)
        metadata = call_metadata(workflow, params, workflow_context, started_at, {:error, error}, nil)
        maybe_record_metadata(context, metadata)

        trace_workflow(context, workflow, :error, %{
          duration_ms: Map.get(metadata, :duration_ms),
          input_keys: Map.get(metadata, :input_keys),
          context_keys: Map.get(metadata, :context_keys),
          error: Jidoka.Error.format(error)
        })

        {:error, error}
    end
  end

  def run_workflow_tool(%{} = workflow, _params, context) do
    error = normalize_workflow_error(workflow, {:invalid_workflow_input, :expected_map}, context)
    maybe_record_metadata(context, error_metadata(workflow, context, error))
    trace_workflow(context, workflow, :error, %{error: Jidoka.Error.format(error)})
    {:error, error}
  end

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

  defp visible_result(%{result: :structured}, output, metadata) do
    %{output: output, workflow: visible_metadata(metadata)}
  end

  defp visible_result(%{}, output, _metadata), do: %{output: output}

  defp visible_metadata(metadata) when is_map(metadata) do
    %{
      name: Map.get(metadata, :name),
      workflow: metadata |> Map.get(:workflow) |> inspect(),
      duration_ms: Map.get(metadata, :duration_ms, 0),
      outcome: visible_outcome(Map.get(metadata, :outcome)),
      input_keys: Map.get(metadata, :input_keys, []),
      context_keys: Map.get(metadata, :context_keys, []),
      output_preview: Map.get(metadata, :output_preview)
    }
  end

  defp visible_outcome(:ok), do: :ok
  defp visible_outcome({:error, reason}), do: {:error, Jidoka.Error.format(reason)}
  defp visible_outcome(other), do: other

  defp call_metadata(workflow, params, context, started_at, outcome, output) do
    %{
      sequence: next_sequence(),
      name: workflow.name,
      workflow: workflow.workflow,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      outcome: outcome,
      input_keys: map_keys(params),
      context_keys: context_keys(context),
      output_preview: output_preview(output)
    }
  end

  defp trace_workflow(context, workflow, event, metadata) do
    measurements =
      case Map.get(metadata, :duration_ms) do
        duration_ms when is_integer(duration_ms) -> %{duration_ms: duration_ms}
        _ -> %{}
      end

    Jidoka.Trace.emit(
      :workflow,
      Jidoka.Trace.correlation_refs(context)
      |> Map.merge(%{
        event: event,
        workflow: workflow.workflow,
        name: workflow.name,
        request_id: Map.get(context, Jidoka.Subagent.Context.request_id_key()),
        agent_id: Map.get(context, Jidoka.Trace.agent_id_key())
      })
      |> Map.merge(metadata),
      measurements
    )
  end

  defp trace_workflow_steps(context, workflow, %{steps: steps}) when is_map(steps) do
    steps
    |> Enum.sort_by(fn {name, _result} -> key_to_string(name) end)
    |> Enum.each(fn {name, result} ->
      trace_workflow(context, workflow, :step, %{
        phase: :step,
        step: key_to_string(name),
        output_preview: output_preview(result)
      })
    end)
  end

  defp trace_workflow_steps(_context, _workflow, _debug), do: :ok

  defp error_metadata(workflow, context, error) do
    %{
      sequence: next_sequence(),
      name: workflow.name,
      workflow: workflow.workflow,
      duration_ms: 0,
      outcome: {:error, error},
      input_keys: [],
      context_keys: context_keys(context),
      output_preview: nil
    }
  end

  defp normalize_workflow_error(workflow, reason, context) do
    Jidoka.Error.Normalize.workflow_error(reason,
      workflow_id: workflow.name,
      target: workflow.workflow,
      request_id: request_id(context),
      cause: reason
    )
  end

  defp maybe_record_metadata(context, metadata) when is_map(context) and is_map(metadata) do
    parent_server = Map.get(context, Jidoka.Subagent.Context.server_key())
    request_id = Map.get(context, Jidoka.Subagent.Context.request_id_key())

    if is_pid(parent_server) and is_binary(request_id) do
      Jidoka.Workflow.Capability.Metadata.insert(parent_server, request_id, metadata)
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
    Jidoka.Workflow.Capability.Metadata.drain(server, request_id)
  end

  defp drain_request_meta(_server, _request_id), do: []

  defp lookup_request_meta(server, request_id) when is_pid(server) and is_binary(request_id) do
    Jidoka.Workflow.Capability.Metadata.lookup(server, request_id)
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

  defp stored_request_calls(%Jido.Agent{} = agent, request_id) do
    case get_request_meta(agent, request_id) do
      %{calls: calls} when is_list(calls) -> calls
      _ -> []
    end
  end

  defp stored_request_calls(server, request_id) do
    try do
      case Jido.AgentServer.state(server) do
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

  defp forwarded_context(context, policy) do
    context
    |> Jidoka.Context.strip_internal()
    |> apply_forward_context_policy(policy)
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

  defp fetch_equivalent_key(context, key) when is_map(context) do
    Enum.find_value(context, :error, fn {existing_key, value} ->
      if equivalent_key?(existing_key, key) do
        {:ok, existing_key, value}
      end
    end)
  end

  defp equivalent_key?(left, right), do: key_to_string(left) == key_to_string(right)

  defp map_keys(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.map(&key_to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp context_keys(context) when is_map(context) do
    context
    |> Map.keys()
    |> Enum.map(&key_to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp context_keys(_context), do: []

  defp output_preview(output) when is_binary(output) do
    output
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp output_preview(output) when is_map(output), do: inspect(output, limit: 8, printable_limit: 140)
  defp output_preview(output) when not is_nil(output), do: inspect(output, limit: 8, printable_limit: 140)
  defp output_preview(nil), do: nil

  defp request_id(context) when is_map(context), do: Map.get(context, Jidoka.Subagent.Context.request_id_key())
  defp request_id(_context), do: nil

  defp request_call_identity(%{sequence: sequence}) when is_integer(sequence), do: {:sequence, sequence}

  defp request_call_identity(call) when is_map(call) do
    {:fallback, Map.get(call, :name), Map.get(call, :workflow), Map.get(call, :input_keys)}
  end

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)
  defp next_sequence, do: System.unique_integer([:positive, :monotonic])
end
