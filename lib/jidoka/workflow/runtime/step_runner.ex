defmodule Jidoka.Workflow.Runtime.StepRunner do
  @moduledoc false

  alias Jidoka.Workflow.Runtime.Value

  @spec execute_step(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def execute_step(_definition, %{kind: :action} = step, state) do
    with {:ok, params} <- Value.resolve_value(step.input, state),
         {:ok, params} <- ensure_map(params, :action_input) do
      Jido.Exec.run(step.target, params, state.context,
        timeout: state.timeout,
        log_level: :warning,
        max_retries: 0
      )
      |> normalize_step_result()
    end
  end

  def execute_step(_definition, %{kind: :function, target: {module, function, 2}} = step, state) do
    with {:ok, params} <- Value.resolve_value(step.input, state),
         {:ok, params} <- ensure_map(params, :function_input) do
      try do
        module
        |> apply(function, [params, state.context])
        |> normalize_function_result()
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end
    end
  end

  def execute_step(_definition, %{kind: :agent} = step, state) do
    with {:ok, prompt} <- Value.resolve_value(step.prompt, state),
         {:ok, prompt} <- ensure_prompt(prompt),
         {:ok, context} <- Value.resolve_value(step.context, state),
         {:ok, context} <- ensure_map(context, :agent_context),
         {:ok, target} <- resolve_agent_target(step.target, state) do
      run_agent_target(target, prompt, context, state.timeout)
    end
  end

  @spec step_error(map(), map(), term()) :: term()
  def step_error(definition, step, reason) do
    Jidoka.Error.execution_error("Workflow #{definition.id} step #{step.name} failed.",
      phase: :workflow_step,
      details: %{
        workflow_id: definition.id,
        step: step.name,
        kind: step.kind,
        target: step.target,
        reason: reason,
        cause: reason
      }
    )
  end

  defp normalize_step_result({:ok, result}), do: {:ok, result}
  defp normalize_step_result({:ok, result, _extra}), do: {:ok, result}
  defp normalize_step_result({:error, reason}), do: {:error, visible_reason(reason)}
  defp normalize_step_result(other), do: {:error, {:invalid_step_result, other}}

  defp normalize_function_result({:ok, result}), do: {:ok, result}
  defp normalize_function_result({:error, reason}), do: {:error, visible_reason(reason)}
  defp normalize_function_result(result), do: {:ok, result}

  defp resolve_agent_target({:imported, key}, state) do
    case Value.fetch_equivalent(state.agents, key) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, {:missing_imported_agent, key}}
    end
  end

  defp resolve_agent_target(target, _state), do: {:ok, target}

  defp run_agent_target(pid, prompt, context, timeout) when is_pid(pid) do
    call_agent(fn -> Jidoka.Chat.chat(pid, prompt, context: context, timeout: timeout) end, timeout)
  end

  defp run_agent_target(%{runtime_module: runtime_module, spec: _spec}, prompt, context, timeout)
       when is_atom(runtime_module) do
    run_started_agent(fn opts -> Jidoka.Runtime.start_agent(runtime_module, opts) end, fn pid ->
      call_agent(fn -> Jidoka.Chat.chat(pid, prompt, context: context, timeout: timeout) end, timeout)
    end)
  end

  defp run_agent_target(module, prompt, context, timeout) when is_atom(module) do
    run_started_agent(fn opts -> module.start_link(opts) end, fn pid ->
      call_agent(fn -> module.chat(pid, prompt, context: context, timeout: timeout) end, timeout)
    end)
  end

  defp run_agent_target(other, _prompt, _context, _timeout), do: {:error, {:invalid_agent_target, other}}

  defp run_started_agent(start_fun, call_fun) do
    child_id = "jidoka-workflow-agent-#{System.unique_integer([:positive])}"

    case normalize_start_result(start_fun.(id: child_id)) do
      {:ok, pid} ->
        try do
          call_fun.(pid)
        after
          _ = Jidoka.Runtime.stop_agent(pid)
        end

      {:error, reason} ->
        {:error, {:start_failed, reason}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp normalize_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp normalize_start_result({:error, reason}), do: {:error, reason}
  defp normalize_start_result(:ignore), do: {:error, :ignore}
  defp normalize_start_result(other), do: {:error, {:invalid_start_return, other}}

  defp call_agent(fun, timeout) do
    task = Task.async(fn -> safe_call(fun) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:ok, result}}} ->
        {:ok, result}

      {:ok, {:ok, {:error, reason}}} ->
        {:error, reason}

      {:ok, {:ok, {:interrupt, interrupt}}} ->
        {:error, {:interrupt, interrupt}}

      {:ok, {:ok, other}} ->
        {:error, {:invalid_agent_result, other}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        {:error, reason}

      nil ->
        {:error, {:timeout, timeout}}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ensure_map(value, _field) when is_map(value), do: {:ok, value}
  defp ensure_map(value, field), do: {:error, {:expected_map, field, value}}

  defp ensure_prompt(prompt) when is_binary(prompt), do: {:ok, prompt}
  defp ensure_prompt(prompt), do: {:error, {:expected_prompt, prompt}}

  defp visible_reason(%{message: message}) when is_binary(message), do: message
  defp visible_reason(reason), do: reason
end
