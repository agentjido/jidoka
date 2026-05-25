defmodule Jidoka.Schedule.Executor do
  @moduledoc false

  alias Jidoka.Schedule

  @preview_bytes 500

  @spec run(Schedule.t(), String.t()) :: map()
  def run(%Schedule{} = schedule, run_id) when is_binary(run_id) do
    started_at_ms = System.system_time(:millisecond)
    request_id = request_id(schedule, run_id)

    emit(schedule, :start, %{
      request_id: request_id,
      run_id: run_id,
      status: :running
    })

    {result, status} =
      try do
        schedule
        |> dispatch(request_id)
        |> normalize_result()
      rescue
        error ->
          {{:error, error}, :failed}
      catch
        kind, reason ->
          {{:error, {kind, reason}}, :failed}
      end

    completed_at_ms = System.system_time(:millisecond)

    run =
      %{
        run_id: run_id,
        request_id: request_id,
        schedule_id: schedule.id,
        kind: schedule.kind,
        status: status,
        started_at_ms: started_at_ms,
        completed_at_ms: completed_at_ms,
        duration_ms: completed_at_ms - started_at_ms,
        result: result,
        result_preview: result_preview(result, status),
        error_preview: error_preview(result, status)
      }

    emit(schedule, event_for_status(status), %{
      request_id: request_id,
      run_id: run_id,
      status: status,
      duration_ms: run.duration_ms,
      result: run.result_preview,
      error: run.error_preview
    })

    run
  end

  defp dispatch(%Schedule{kind: :agent, target: %Jidoka.Session{} = session} = schedule, request_id) do
    with {:ok, prompt} <- resolve_prompt(schedule.prompt),
         {:ok, context} <- resolve_payload(schedule.context, :context) do
      chat_opts = chat_opts(schedule, context, request_id)
      Jidoka.chat(session, prompt, chat_opts)
    end
  end

  defp dispatch(%Schedule{kind: :agent} = schedule, request_id) do
    with {:ok, prompt} <- resolve_prompt(schedule.prompt),
         {:ok, context} <- resolve_payload(schedule.context, :context),
         {:ok, pid} <- resolve_agent(schedule) do
      chat_opts = chat_opts(schedule, context, request_id)
      Jidoka.chat(pid, prompt, chat_opts)
    end
  end

  defp dispatch(%Schedule{kind: :workflow} = schedule, _request_id) do
    with {:ok, input} <- resolve_payload(schedule.input, :input),
         {:ok, context} <- resolve_payload(schedule.context, :context) do
      workflow_opts =
        schedule.opts
        |> Keyword.put_new(:context, context)
        |> Keyword.put_new(:timeout, schedule.timeout)

      Jidoka.Workflow.run(schedule.target, input, workflow_opts)
    end
  end

  defp normalize_result({:ok, _result} = result), do: {result, :completed}
  defp normalize_result({:interrupt, _interrupt} = result), do: {result, :interrupted}
  defp normalize_result({:handoff, _handoff} = result), do: {result, :handoff}
  defp normalize_result({:error, _reason} = result), do: {result, :failed}
  defp normalize_result(other), do: {{:ok, other}, :completed}

  defp resolve_prompt(prompt) do
    with {:ok, resolved} <- resolve_value(prompt, :prompt) do
      case resolved do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> {:error, validation_error("Schedule prompt must not be empty.", :prompt, value)}
            trimmed -> {:ok, trimmed}
          end

        value ->
          {:error, validation_error("Schedule prompt callback must return a string.", :prompt, value)}
      end
    end
  end

  defp resolve_payload(source, field) do
    with {:ok, resolved} <- resolve_value(source, field) do
      cond do
        is_map(resolved) ->
          {:ok, resolved}

        is_list(resolved) and Keyword.keyword?(resolved) ->
          {:ok, Map.new(resolved)}

        true ->
          {:error, validation_error("Schedule #{field} callback must return a map or keyword list.", field, resolved)}
      end
    end
  end

  defp resolve_value(fun, _field) when is_function(fun, 0), do: normalize_callback_result(fun.())

  defp resolve_value({module, function, args}, _field) when is_atom(module) and is_atom(function) and is_list(args),
    do: normalize_callback_result(apply(module, function, args))

  defp resolve_value(value, _field), do: {:ok, value}

  defp normalize_callback_result({:ok, value}), do: {:ok, value}
  defp normalize_callback_result({:error, reason}), do: {:error, reason}
  defp normalize_callback_result(value), do: {:ok, value}

  defp resolve_agent(%Schedule{target: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      {:error, Jidoka.Error.execution_error("Scheduled agent process is not alive.", phase: :schedule)}
    end
  end

  defp resolve_agent(%Schedule{target: id, runtime: runtime, start_opts: opts}) when is_binary(id) do
    case whereis(runtime, id, opts) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, Jidoka.Error.validation_error("Scheduled agent could not be found.", field: :agent, value: id)}
    end
  end

  defp resolve_agent(%Schedule{target: module} = schedule) when is_atom(module) do
    runtime = schedule.runtime
    agent_id = schedule.agent_id || schedule.id

    case whereis(runtime, agent_id, schedule.start_opts) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_agent(runtime, module, agent_id, schedule.start_opts)
    end
  end

  defp resolve_agent(%Schedule{target: %Jidoka.Session{} = session}) do
    Jidoka.Session.start_agent(session)
  end

  defp resolve_agent(%Schedule{target: target}) do
    {:error,
     Jidoka.Error.validation_error("Schedule target must be a PID, agent id, or agent module.",
       field: :target,
       value: target
     )}
  end

  defp start_agent(runtime, public_module, agent_id, start_opts) do
    runtime_module =
      if function_exported?(public_module, :runtime_module, 0) do
        public_module.runtime_module()
      else
        public_module
      end

    opts = Keyword.put_new(start_opts, :id, agent_id)

    result =
      cond do
        runtime == Jidoka.Runtime and function_exported?(public_module, :start_link, 1) ->
          public_module.start_link(opts)

        function_exported?(runtime, :start_agent, 2) ->
          runtime.start_agent(runtime_module, opts)

        true ->
          {:error,
           Jidoka.Error.config_error("Schedule runtime does not expose start_agent/2.",
             field: :runtime,
             value: runtime
           )}
      end

    normalize_start_result(result, runtime, agent_id, start_opts)
  end

  defp normalize_start_result({:ok, pid}, _runtime, _agent_id, _opts) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:ok, pid, _info}, _runtime, _agent_id, _opts) when is_pid(pid), do: {:ok, pid}

  defp normalize_start_result({:error, {:already_registered, pid}}, _runtime, _agent_id, _opts) when is_pid(pid),
    do: {:ok, pid}

  defp normalize_start_result({:error, _reason} = error, runtime, agent_id, opts) do
    case whereis(runtime, agent_id, opts) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> error
    end
  end

  defp normalize_start_result(other, _runtime, _agent_id, _opts), do: other

  defp whereis(runtime, agent_id, opts) do
    if function_exported?(runtime, :whereis, 2) do
      runtime.whereis(agent_id, opts)
    else
      nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp module_id(module) do
    cond do
      function_exported?(module, :id, 0) -> module.id()
      true -> nil
    end
  end

  defp chat_opts(%Schedule{} = schedule, context, request_id) do
    schedule.opts
    |> merge_context(context)
    |> Keyword.put_new(:request_id, request_id)
    |> Keyword.put_new(:timeout, schedule.timeout)
    |> maybe_put_conversation(schedule.conversation)
  end

  defp merge_context(opts, context) do
    base =
      case Keyword.get(opts, :context, %{}) do
        values when is_map(values) -> values
        values when is_list(values) -> keyword_context(values)
        _other -> %{}
      end

    Keyword.put(opts, :context, Map.merge(base, context))
  end

  defp maybe_put_conversation(opts, nil), do: opts
  defp maybe_put_conversation(opts, conversation), do: Keyword.put_new(opts, :conversation, conversation)

  defp keyword_context(values) do
    if Keyword.keyword?(values), do: Map.new(values), else: %{}
  end

  defp request_id(%Schedule{kind: :agent}, run_id), do: run_id
  defp request_id(%Schedule{kind: :workflow}, run_id), do: run_id

  defp event_for_status(:completed), do: :stop
  defp event_for_status(:interrupted), do: :interrupt
  defp event_for_status(:handoff), do: :handoff
  defp event_for_status(_status), do: :error

  defp emit(%Schedule{} = schedule, event, extra) do
    metadata =
      %{
        event: event,
        schedule_id: schedule.id,
        name: schedule.id,
        kind: schedule.kind,
        agent_id: schedule.agent_id || schedule_id_for_trace(schedule),
        cron: schedule.cron,
        timezone: schedule.timezone
      }
      |> Map.merge(schedule_correlation_refs(schedule))
      |> Map.merge(extra)

    Jidoka.Trace.emit(:schedule, metadata)
  end

  defp schedule_correlation_refs(%Schedule{target: %Jidoka.Session{} = session}) do
    %{
      session_id: session.id,
      conversation_id: session.conversation_id,
      context_ref: session.context_ref
    }
  end

  defp schedule_correlation_refs(_schedule), do: %{}

  defp schedule_id_for_trace(%Schedule{target: target}) when is_binary(target), do: target
  defp schedule_id_for_trace(%Schedule{target: %Jidoka.Session{} = session}), do: session.agent_id
  defp schedule_id_for_trace(%Schedule{kind: :workflow, target: target}) when is_atom(target), do: module_id(target)
  defp schedule_id_for_trace(%Schedule{kind: :agent, id: id, target: target}) when is_atom(target), do: id
  defp schedule_id_for_trace(%Schedule{id: id}), do: id

  defp result_preview(result, :completed), do: Jidoka.Sanitize.preview(result, @preview_bytes)
  defp result_preview(_result, _status), do: nil

  defp error_preview({:error, reason}, _status), do: Jidoka.Error.format(reason)
  defp error_preview(_result, :failed), do: "Scheduled run failed."
  defp error_preview(_result, _status), do: nil

  defp validation_error(message, field, value) do
    Jidoka.Error.validation_error(message,
      field: field,
      value: value,
      details: %{operation: :schedule}
    )
  end
end
