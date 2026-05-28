defmodule Jidoka.Schedule.Manager do
  @moduledoc """
  Supervised in-memory schedule manager for Jidoka.

  The default Jidoka application starts one manager under the registered name
  `Jidoka.Schedule.Manager`. Applications that need isolated schedule sets can
  start their own named manager and pass `manager: MyApp.ScheduleManager` to the
  public schedule APIs.

  Manager state is process-local and non-durable by design. The registered
  schedules, cron scheduler pids, currently running tasks, and bounded run
  history are lost when the manager stops. To rebuild schedules on application
  boot, pass compiled schedule metadata with `start_link(schedules: schedules)`
  or register schedules from your application's startup code.

  Run history is for short-lived diagnostics and UI feedback. It is not a
  durable audit log, replay source, or recovery journal.

  Manual `run/2` calls return `{:ok, run}` when the manager records the run.
  Callers must inspect `run.status` to distinguish successful work from recorded
  failures, interrupts, handoffs, and skips.
  """

  use GenServer

  alias Jidoka.Schedule
  alias Jidoka.Schedule.Executor

  @default_history_limit 20

  defstruct name: __MODULE__,
            history_limit: @default_history_limit,
            schedules: %{},
            order: [],
            running: %{}

  @type manager :: GenServer.server()

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Starts a schedule manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a recurring agent schedule."
  @spec schedule(Schedule.target(), keyword()) :: {:ok, Schedule.t()} | {:error, term()}
  def schedule(target, opts) when is_list(opts) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:schedule, target, Keyword.delete(opts, :manager)})
  end

  @doc "Registers an already-built schedule."
  @spec put_schedule(Schedule.t(), keyword()) :: {:ok, Schedule.t()} | {:error, term()}
  def put_schedule(%Schedule{} = schedule, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:put_schedule, schedule, Keyword.delete(opts, :manager)})
  end

  @doc "Lists schedules in registration order."
  @spec list(keyword()) :: {:ok, [Schedule.t()]} | {:error, term()}
  def list(opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:list, opts})
  end

  @doc "Cancels and removes a schedule."
  @spec cancel(String.t() | atom(), keyword()) :: :ok | {:error, term()}
  def cancel(id, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:cancel, normalize_id(id)})
  end

  @doc "Runs a schedule immediately and waits for the result."
  @spec run(String.t() | atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(id, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    timeout = Keyword.get(opts, :call_timeout, :infinity)
    GenServer.call(manager, {:run, normalize_id(id), opts}, timeout)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.get(opts, :name, __MODULE__),
      history_limit: normalize_history_limit(Keyword.get(opts, :history_limit, @default_history_limit))
    }

    schedules = Keyword.get(opts, :schedules, [])

    case register_initial_schedules(state, schedules) do
      {:ok, state} -> {:ok, state}
      {:error, reason, _state} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:schedule, target, opts}, _from, state) do
    replace? = Keyword.get(opts, :replace, false)

    with {:ok, schedule} <- Schedule.new(target, opts),
         {:ok, state, schedule} <- register_schedule(state, schedule, replace?) do
      {:reply, {:ok, schedule}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_schedule, %Schedule{} = schedule, opts}, _from, state) do
    replace? = Keyword.get(opts, :replace, false)

    case register_schedule(state, schedule, replace?) do
      {:ok, state, schedule} -> {:reply, {:ok, schedule}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    schedules =
      state.order
      |> Enum.map(&Map.fetch!(state.schedules, &1))
      |> maybe_limit(Keyword.get(opts, :limit))

    {:reply, {:ok, schedules}, state}
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.pop(state.schedules, id) do
      {nil, _schedules} ->
        {:reply, {:error, :not_found}, state}

      {%Schedule{} = schedule, schedules} ->
        cancel_scheduler(schedule)
        order = List.delete(state.order, id)
        {:reply, :ok, %{state | schedules: schedules, order: order}}
    end
  end

  def handle_call({:run, id, _opts}, from, state) do
    case start_run(state, id, from, :manual) do
      {:ok, state} -> {:noreply, state}
      {:reply, reply, state} -> {:reply, reply, state}
    end
  end

  @impl true
  def handle_info({:schedule_tick, id}, state) do
    case start_run(state, id, nil, :scheduled) do
      {:ok, state} -> {:noreply, state}
      {:reply, _reply, state} -> {:noreply, state}
    end
  end

  def handle_info({ref, run}, state) when is_reference(ref) and is_map(run) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.running, ref) do
      {nil, running} ->
        {:noreply, %{state | running: running}}

      {run_state, running} ->
        run = Map.put_new(run, :trigger, run_state.trigger)

        state =
          state
          |> Map.put(:running, running)
          |> finish_run(run_state, run)

        reply_to_caller(run_state.from, {:ok, run})

        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, running} ->
        {:noreply, %{state | running: running}}

      {run_state, running} ->
        run = failed_run(run_state, reason)

        state =
          state
          |> Map.put(:running, running)
          |> finish_run(run_state, run)

        reply_to_caller(run_state.from, {:ok, run})

        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp register_initial_schedules(state, schedules) when is_list(schedules) do
    Enum.reduce_while(schedules, {:ok, state}, fn schedule, {:ok, acc} ->
      case put_initial_schedule(acc, schedule) do
        {:ok, next_state, _schedule} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason, acc}}
      end
    end)
  end

  defp register_initial_schedules(state, _schedules), do: {:error, :invalid_schedules, state}

  defp put_initial_schedule(state, %Schedule{} = schedule), do: register_schedule(state, schedule, true)
  defp put_initial_schedule(_state, other), do: {:error, {:invalid_schedule, other}}

  defp register_schedule(state, %Schedule{id: id} = schedule, replace?) do
    cond do
      Map.has_key?(state.schedules, id) and not replace? ->
        {:error,
         Jidoka.Error.validation_error("Schedule `#{id}` is already registered.",
           field: :id,
           value: id,
           details: %{reason: :schedule_already_registered}
         )}

      true ->
        state = maybe_cancel_existing(state, id)

        with {:ok, schedule} <- maybe_start_scheduler(state, schedule) do
          schedules = Map.put(state.schedules, id, schedule)
          order = if id in state.order, do: state.order, else: state.order ++ [id]

          {:ok, %{state | schedules: schedules, order: order}, schedule}
        end
    end
  end

  defp maybe_start_scheduler(_state, %Schedule{enabled?: false} = schedule), do: {:ok, %{schedule | status: :disabled}}

  defp maybe_start_scheduler(state, %Schedule{} = schedule) do
    manager = self()

    case Jido.Scheduler.run_every(fn -> send(manager, {:schedule_tick, schedule.id}) end, schedule.cron,
           timezone: schedule.timezone
         ) do
      {:ok, pid} ->
        {:ok, Schedule.put_scheduler_pid(schedule, pid)}

      {:error, reason} ->
        {:error,
         Jidoka.Error.validation_error("Schedule cron expression is invalid.",
           field: :cron,
           value: schedule.cron,
           details: %{reason: :invalid_cron, cause: reason, timezone: schedule.timezone, manager: state.name}
         )}
    end
  end

  defp maybe_cancel_existing(state, id) do
    case Map.get(state.schedules, id) do
      %Schedule{} = schedule -> cancel_scheduler(schedule)
      _other -> :ok
    end

    state
  end

  defp cancel_scheduler(%Schedule{scheduler_pid: pid}) when is_pid(pid), do: Jido.Scheduler.cancel(pid)
  defp cancel_scheduler(_schedule), do: :ok

  defp start_run(state, id, from, trigger) do
    case Map.fetch(state.schedules, id) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, %Schedule{running?: true, overlap: :skip} = schedule} ->
        run = skipped_run(schedule, trigger)
        state = put_registered_schedule(state, Schedule.record_run(schedule, run, state.history_limit))
        {:reply, {:ok, run}, state}

      {:ok, %Schedule{} = schedule} ->
        run_id = run_id(schedule)
        started_at_ms = System.system_time(:millisecond)
        schedule = Schedule.starting(schedule, started_at_ms)
        state = put_registered_schedule(state, schedule)

        task =
          Task.Supervisor.async_nolink(Jidoka.Schedule.TaskSupervisor, fn ->
            Executor.run(schedule, run_id)
          end)

        running =
          Map.put(state.running, task.ref, %{
            id: id,
            from: from,
            run_id: run_id,
            started_at_ms: started_at_ms,
            trigger: trigger
          })

        {:ok, %{state | running: running}}
    end
  end

  defp finish_run(state, %{id: id}, run) do
    case Map.fetch(state.schedules, id) do
      {:ok, %Schedule{} = schedule} ->
        put_registered_schedule(state, Schedule.record_run(schedule, history_run(run), state.history_limit))

      :error ->
        state
    end
  end

  defp put_registered_schedule(state, %Schedule{id: id} = schedule),
    do: %{state | schedules: Map.put(state.schedules, id, schedule)}

  defp skipped_run(%Schedule{} = schedule, trigger) do
    now = System.system_time(:millisecond)
    run_id = run_id(schedule)

    run = %{
      run_id: run_id,
      request_id: run_id,
      schedule_id: schedule.id,
      kind: schedule.kind,
      trigger: trigger,
      status: :skipped,
      reason: :overlap,
      started_at_ms: now,
      completed_at_ms: now,
      duration_ms: 0,
      result: {:skip, :overlap},
      result_preview: nil,
      error_preview: nil
    }

    Jidoka.Trace.emit(
      :schedule,
      %{
        event: :skip,
        schedule_id: schedule.id,
        name: schedule.id,
        kind: schedule.kind,
        agent_id: schedule.agent_id || schedule.id,
        request_id: run_id,
        run_id: run_id,
        status: :skipped,
        reason: :overlap
      }
      |> Map.merge(schedule_correlation_refs(schedule))
    )

    run
  end

  defp failed_run(run_state, reason) do
    now = System.system_time(:millisecond)

    %{
      run_id: run_state.run_id,
      request_id: run_state.run_id,
      schedule_id: run_state.id,
      kind: :unknown,
      trigger: run_state.trigger,
      status: :failed,
      started_at_ms: run_state.started_at_ms,
      completed_at_ms: now,
      duration_ms: now - run_state.started_at_ms,
      result: {:error, reason},
      result_preview: nil,
      error_preview: inspect(reason)
    }
  end

  defp history_run(run), do: Map.delete(run, :result)

  defp reply_to_caller(nil, _reply), do: :ok
  defp reply_to_caller(from, reply), do: GenServer.reply(from, reply)

  defp run_id(%Schedule{id: id}) do
    "schedule-#{id}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp schedule_correlation_refs(%Schedule{target: %Jidoka.Session{} = session}) do
    %{
      session_id: session.id,
      conversation_id: session.conversation_id,
      context_ref: session.context_ref
    }
  end

  defp schedule_correlation_refs(_schedule), do: %{}

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id), do: id

  defp normalize_history_limit(value) when is_integer(value) and value > 0, do: value
  defp normalize_history_limit(_value), do: @default_history_limit

  defp maybe_limit(values, nil), do: values
  defp maybe_limit(values, limit) when is_integer(limit) and limit >= 0, do: Enum.take(values, limit)
  defp maybe_limit(values, _limit), do: values
end
