defmodule Jidoka.Runtime.CapabilityInvoker do
  @moduledoc false

  alias Jidoka.Effect
  alias Jidoka.Turn

  @task_supervisor Jidoka.Runtime.TaskSupervisor

  @spec invoke(function(), Effect.Intent.t(), Effect.Journal.t(), Jidoka.Context.t(), Turn.State.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | term()
  def invoke(capability, %Effect.Intent{} = intent, %Effect.Journal{} = journal, %Jidoka.Context{} = ctx, state, opts)
      when is_function(capability, 3) do
    timeout = capability_timeout(state, opts)

    case timeout do
      :infinity -> safe_invoke(capability, intent, journal, ctx)
      timeout_ms -> invoke_with_timeout(capability, intent, journal, ctx, timeout_ms)
    end
  end

  defp invoke_with_timeout(capability, intent, journal, ctx, timeout_ms) do
    task = async_task(fn -> safe_invoke(capability, intent, journal, ctx) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:capability_exit, reason}}
      nil -> {:error, {:capability_timeout, intent.kind, timeout_ms}}
    end
  end

  defp async_task(fun) do
    Task.Supervisor.async_nolink(@task_supervisor, fun)
  end

  defp safe_invoke(capability, intent, journal, ctx) do
    capability.(intent, journal, ctx)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec capability_timeout(Turn.State.t(), keyword()) :: pos_integer() | :infinity
  def capability_timeout(%Turn.State{} = state, opts) do
    configured_timeout = normalize_timeout(Keyword.get(opts, :capability_timeout_ms))
    remaining_timeout = remaining_turn_timeout(state, opts)

    min_timeout(configured_timeout, remaining_timeout)
  end

  defp remaining_turn_timeout(%Turn.State{plan: %{timeout_ms: timeout_ms}, started_at_ms: started_at_ms}, opts)
       when is_integer(timeout_ms) and is_integer(started_at_ms) do
    remaining = timeout_ms - (clock_ms(opts) - started_at_ms)
    max(1, remaining)
  end

  defp remaining_turn_timeout(%Turn.State{plan: %{timeout_ms: timeout_ms}}, _opts) when is_integer(timeout_ms) do
    timeout_ms
  end

  defp remaining_turn_timeout(_state, _opts), do: :infinity

  defp normalize_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: timeout_ms
  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(_timeout_ms), do: :infinity

  defp min_timeout(:infinity, timeout), do: timeout
  defp min_timeout(timeout, :infinity), do: timeout
  defp min_timeout(left, right), do: min(left, right)

  defp clock_ms(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _clock -> System.system_time(:millisecond)
    end
  end
end
