defmodule Jidoka.Runtime.CapabilityInvoker do
  @moduledoc false

  alias Jidoka.Cancellation
  alias Jidoka.Cancellation.Token
  alias Jidoka.Effect
  alias Jidoka.Runtime.Limits
  alias Jidoka.Turn

  @task_supervisor Jidoka.Runtime.TaskSupervisor

  @spec invoke(function(), Effect.Intent.t(), Effect.Journal.t(), Jidoka.Context.t(), Turn.State.t(), keyword()) ::
          {:ok, term()} | {:error, term()} | term()
  def invoke(capability, %Effect.Intent{} = intent, %Effect.Journal{} = journal, %Jidoka.Context{} = ctx, state, opts)
      when is_function(capability, 3) do
    with :ok <- Cancellation.check(opts) do
      timeout = capability_timeout(state, opts)

      if cancellable?(opts) or timeout != :infinity do
        invoke_in_task(capability, intent, journal, ctx, timeout, opts)
      else
        safe_invoke(capability, intent, journal, ctx)
      end
    end
  end

  defp invoke_in_task(capability, intent, journal, ctx, timeout, opts) do
    task = async_task(fn -> safe_invoke(capability, intent, journal, ctx) end)
    maybe_register_task(task, opts)
    started_at_ms = System.monotonic_time(:millisecond)
    await_task(task, intent, timeout, started_at_ms, opts)
  end

  defp await_task(task, intent, timeout, started_at_ms, opts) do
    case Cancellation.check(opts) do
      {:error, :cancelled} ->
        _shutdown = Task.shutdown(task, :brutal_kill)
        {:error, :cancelled}

      :ok ->
        yield_task(task, intent, timeout, started_at_ms, opts)
    end
  end

  defp yield_task(task, intent, timeout, started_at_ms, opts) do
    wait_ms = wait_ms(timeout, started_at_ms, opts)

    case Task.yield(task, wait_ms) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:capability_exit, reason}}
      nil -> continue_or_timeout(task, intent, timeout, started_at_ms, opts)
    end
  end

  defp continue_or_timeout(task, intent, :infinity, started_at_ms, opts) do
    await_task(task, intent, :infinity, started_at_ms, opts)
  end

  defp continue_or_timeout(task, intent, timeout_ms, started_at_ms, opts) do
    if elapsed_ms(started_at_ms) >= timeout_ms do
      case Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:capability_exit, reason}}
        nil -> {:error, {:capability_timeout, intent.kind, timeout_ms}}
      end
    else
      await_task(task, intent, timeout_ms, started_at_ms, opts)
    end
  end

  defp wait_ms(:infinity, _started_at_ms, opts), do: poll_interval_ms(opts)

  defp wait_ms(timeout_ms, started_at_ms, opts) do
    remaining_ms = max(timeout_ms - elapsed_ms(started_at_ms), 1)
    min(remaining_ms, poll_interval_ms(opts))
  end

  defp elapsed_ms(started_at_ms), do: System.monotonic_time(:millisecond) - started_at_ms

  defp poll_interval_ms(opts) do
    case Keyword.get(opts, :cancellation_poll_interval_ms, 10) do
      interval when is_integer(interval) and interval > 0 -> interval
      _interval -> 10
    end
  end

  defp cancellable?(opts), do: not is_nil(Keyword.get(opts, :cancellation))

  defp async_task(fun) do
    owner = self()
    Task.Supervisor.async_nolink(@task_supervisor, fn -> run_owned_capability(owner, fun) end)
  end

  defp run_owned_capability(owner, fun) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)
    result_ref = make_ref()
    parent = self()
    worker = spawn_link(fn -> send(parent, {result_ref, fun.()}) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(owner_ref, [:flush])
        result

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        exit(:shutdown)

      {:EXIT, ^worker, reason} ->
        Process.demonitor(owner_ref, [:flush])
        {:error, {:capability_exit, reason}}
    end
  end

  defp maybe_register_task(%Task{pid: pid}, opts) do
    case Keyword.get(opts, :cancellation) do
      %Token{} = token -> Token.register(token, pid)
      _token -> :ok
    end
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

    configured_timeout
    |> min_timeout(remaining_timeout)
    |> then(&Limits.capability_timeout(opts, &1))
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
