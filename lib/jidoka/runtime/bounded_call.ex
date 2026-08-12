defmodule Jidoka.Runtime.BoundedCall do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Runtime.Limits
  alias Jidoka.Runtime.Limits.Exceeded

  @task_supervisor Jidoka.Runtime.TaskSupervisor

  @doc false
  @spec run((-> term()), atom(), keyword()) :: term()
  def run(function, effect_kind, opts) when is_function(function, 0) and is_atom(effect_kind) do
    timeout = Limits.capability_timeout(opts, :infinity)

    if timeout == :infinity and is_nil(Keyword.get(opts, :cancellation)) do
      safe_run(function)
    else
      task = Task.Supervisor.async_nolink(@task_supervisor, fn -> safe_run(function) end)
      maybe_register(task, opts)
      await(task, effect_kind, timeout, System.monotonic_time(:millisecond), opts)
    end
  end

  defp await(task, effect_kind, timeout, started_at_ms, opts) do
    case Cancellation.check(opts) do
      {:error, :cancelled} ->
        _shutdown = Task.shutdown(task, :brutal_kill)
        {:error, :cancelled}

      :ok ->
        wait_ms = wait_ms(timeout, started_at_ms, opts)

        case Task.yield(task, wait_ms) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:bounded_call_exit, effect_kind, reason}}
          nil -> continue(task, effect_kind, timeout, started_at_ms, opts)
        end
    end
  end

  defp continue(task, effect_kind, :infinity, started_at_ms, opts),
    do: await(task, effect_kind, :infinity, started_at_ms, opts)

  defp continue(task, effect_kind, timeout, started_at_ms, opts) do
    elapsed = System.monotonic_time(:millisecond) - started_at_ms

    if elapsed >= timeout do
      _shutdown = Task.shutdown(task, :brutal_kill)

      {:error,
       {:runtime_limit_exceeded,
        Exceeded.new!(
          kind: :capability_timeout,
          limit: timeout,
          observed: elapsed,
          effect_kind: effect_kind
        )}}
    else
      await(task, effect_kind, timeout, started_at_ms, opts)
    end
  end

  defp wait_ms(:infinity, _started_at_ms, opts), do: poll_interval_ms(opts)

  defp wait_ms(timeout, started_at_ms, opts) do
    elapsed = System.monotonic_time(:millisecond) - started_at_ms
    min(max(timeout - elapsed, 1), poll_interval_ms(opts))
  end

  defp poll_interval_ms(opts) do
    case Keyword.get(opts, :cancellation_poll_interval_ms, 10) do
      value when is_integer(value) and value > 0 -> value
      _value -> 10
    end
  end

  defp maybe_register(%Task{pid: pid}, opts) do
    case Keyword.get(opts, :cancellation) do
      %Token{} = token -> Token.register(token, pid)
      _token -> :ok
    end
  end

  defp safe_run(function) do
    function.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
