defmodule Jidoka.Workflow.Scheduler do
  @moduledoc """
  OTP scheduler that creates normal `Jidoka.Workflow.Background` runs.

  The scheduler owns schedule definitions, timers, append-only trigger history,
  and a separate index of active runs. Use an application supervisor for
  lifecycle ownership. Set `auto_schedule: false` in deterministic tests and
  call `trigger_due/2` with an explicit time.
  """

  use GenServer

  alias Jidoka.Workflow.{Background, Run, Schedule}
  alias Jidoka.Workflow.Runtime.Retry
  alias Jidoka.Workflow.Schedule.Trigger

  @type server :: GenServer.server()

  @doc "Returns a child specification for a named workflow scheduler."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Starts a scheduler for one named background workflow runner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Adds one validated schedule."
  @spec add(server(), keyword() | map()) :: {:ok, Schedule.t()} | {:error, term()}
  def add(server, attrs), do: GenServer.call(server, {:add, attrs})

  @doc "Returns one schedule by ID."
  @spec get(server(), String.t()) :: {:ok, Schedule.t()} | {:error, :not_found}
  def get(server, schedule_id), do: GenServer.call(server, {:get, schedule_id})

  @doc "Lists all schedules in stable ID order."
  @spec list(server()) :: [Schedule.t()]
  def list(server), do: GenServer.call(server, :list)

  @doc "Returns trigger history for one schedule in chronological order."
  @spec history(server(), String.t()) :: [Trigger.t()]
  def history(server, schedule_id), do: GenServer.call(server, {:history, schedule_id})

  @doc "Triggers one schedule immediately while applying overlap and retry policy."
  @spec trigger(server(), String.t(), DateTime.t() | nil) :: {:ok, Trigger.t()} | {:error, term()}
  def trigger(server, schedule_id, now \\ nil), do: GenServer.call(server, {:trigger, schedule_id, now})

  @doc "Triggers every due schedule at an explicit time."
  @spec trigger_due(server(), DateTime.t() | nil) :: [Trigger.t()]
  def trigger_due(server, now \\ nil), do: GenServer.call(server, {:trigger_due, now})

  @doc "Cancels future triggers and applies the declared active-run policy."
  @spec cancel(server(), String.t()) :: {:ok, Schedule.t()} | {:error, :not_found}
  def cancel(server, schedule_id), do: GenServer.call(server, {:cancel, schedule_id})

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       runner: Keyword.fetch!(opts, :runner),
       background: Keyword.get(opts, :background, Background),
       schedules: %{},
       history: %{},
       active_runs: %{},
       timers: %{},
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       auto_schedule: Keyword.get(opts, :auto_schedule, true),
       notification_target: Keyword.get(opts, :name) || self()
     }}
  end

  @impl GenServer
  def handle_call({:add, attrs}, _from, state) do
    now = state.clock.()

    case Schedule.new(attrs, now: now) do
      {:ok, %Schedule{} = schedule} ->
        if Map.has_key?(state.schedules, schedule.id) do
          {:reply, {:error, {:schedule_already_exists, schedule.id}}, state}
        else
          state = put_schedule(state, schedule)
          {:reply, {:ok, schedule}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:get, schedule_id}, _from, state) do
    case Map.fetch(state.schedules, schedule_id) do
      {:ok, schedule} -> {:reply, {:ok, schedule}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    schedules = state.schedules |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, schedules, state}
  end

  def handle_call({:history, schedule_id}, _from, state) do
    {:reply, Map.get(state.history, schedule_id, []), state}
  end

  def handle_call({:trigger, schedule_id, supplied_now}, _from, state) do
    now = supplied_now || state.clock.()

    case Map.fetch(state.schedules, schedule_id) do
      {:ok, schedule} ->
        {trigger, state} = fire(schedule, now, state, false)
        {:reply, {:ok, trigger}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:trigger_due, supplied_now}, _from, state) do
    now = supplied_now || state.clock.()

    {triggers, state} =
      state.schedules
      |> Map.values()
      |> Enum.filter(&due?(&1, now))
      |> Enum.sort_by(& &1.id)
      |> Enum.map_reduce(state, fn schedule, acc -> fire(schedule, now, acc, true) end)

    {:reply, triggers, state}
  end

  def handle_call({:cancel, schedule_id}, _from, state) do
    case Map.fetch(state.schedules, schedule_id) do
      {:ok, schedule} ->
        state = cancel_timer(state, schedule.id)
        state = maybe_cancel_active_runs(schedule, state)
        cancelled = %{schedule | enabled: false, next_at: nil}
        {:reply, {:ok, cancelled}, put_in(state, [:schedules, schedule.id], cancelled)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_cast({:schedule_run_terminal, schedule_id, run_id}, state) do
    {:noreply, delete_active_run(state, schedule_id, run_id)}
  end

  @impl GenServer
  def handle_info({:schedule_due, schedule_id, due_at}, state) do
    case Map.fetch(state.schedules, schedule_id) do
      {:ok, %Schedule{next_at: ^due_at} = schedule} ->
        {_trigger, state} = fire(schedule, state.clock.(), state, true)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def code_change(_old_vsn, state, _extra) do
    state =
      state
      |> Map.put_new(:background, Background)
      |> Map.put_new(:active_runs, %{})
      |> Map.put_new(:notification_target, self())

    {:ok, rebuild_active_runs(state)}
  end

  @doc false
  @spec notify_run_terminal(String.t(), term(), server(), String.t()) :: :ok
  def notify_run_terminal(run_id, _workflow, scheduler, schedule_id) do
    GenServer.cast(scheduler, {:schedule_run_terminal, schedule_id, run_id})
  end

  defp fire(%Schedule{} = schedule, now, state, advance?) do
    due_at = schedule.next_at || now

    {overlap?, state} =
      if schedule.overlap == :skip do
        active_run?(schedule, state)
      else
        {false, state}
      end

    {trigger, state} =
      cond do
        not schedule.enabled ->
          record(schedule, due_at, now, :cancelled, nil, :schedule_disabled, 1, state)

        misfired?(schedule, now) and schedule.misfire == :skip ->
          record(schedule, due_at, now, :skipped, nil, :misfire, 1, state)

        overlap? ->
          record(schedule, due_at, now, :skipped, nil, :overlap, 1, state)

        true ->
          submit(schedule, due_at, now, state)
      end

    state = if advance?, do: advance_schedule(schedule, max_datetime(due_at, now), state), else: state
    {trigger, state}
  end

  defp submit(schedule, due_at, now, state) do
    case Jidoka.Id.generate("run", Keyword.get(schedule.run_opts, :id_generator)) do
      {:ok, run_id} -> submit_with_retry(schedule, due_at, now, run_id, state)
      {:error, reason} -> record(schedule, due_at, now, :failed, nil, reason, 1, state)
    end
  end

  defp submit_with_retry(schedule, due_at, now, run_id, state) do
    {:ok, attempt_counter} = Elixir.Agent.start_link(fn -> 0 end)

    run_opts =
      schedule.run_opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(
        :on_complete,
        {__MODULE__, :notify_run_terminal, [state.notification_target, schedule.id]}
      )

    result =
      Retry.call(schedule.retry, fn ->
        Elixir.Agent.update(attempt_counter, &(&1 + 1))
        state.background.submit(state.runner, schedule.workflow, schedule.input, run_opts)
      end)

    attempt_count = Elixir.Agent.get(attempt_counter, & &1)
    Elixir.Agent.stop(attempt_counter)

    case result do
      {:ok, ^run_id} -> record(schedule, due_at, now, :started, run_id, nil, attempt_count, state)
      {:error, reason} -> record(schedule, due_at, now, :failed, nil, reason, attempt_count, state)
    end
  end

  defp record(schedule, due_at, now, status, run_id, reason, attempts, state) do
    trigger = %Trigger{
      schedule_id: schedule.id,
      due_at: due_at,
      triggered_at: now,
      status: status,
      run_id: run_id,
      reason: reason,
      attempts: attempts
    }

    history = Map.update(state.history, schedule.id, [trigger], &(&1 ++ [trigger]))
    state = %{state | history: history}
    state = if status == :started, do: put_active_run(state, schedule.id, run_id), else: state
    {trigger, state}
  end

  defp advance_schedule(schedule, due_at, state) do
    state = cancel_timer(state, schedule.id)

    case Schedule.advance(schedule, due_at) do
      {:ok, schedule} -> put_schedule(state, schedule)
      {:error, _reason} -> put_schedule(state, %{schedule | enabled: false, next_at: nil})
    end
  end

  defp put_schedule(state, %Schedule{} = schedule) do
    state = put_in(state, [:schedules, schedule.id], schedule)
    maybe_schedule_timer(state, schedule)
  end

  defp maybe_schedule_timer(%{auto_schedule: false} = state, _schedule), do: state
  defp maybe_schedule_timer(state, %Schedule{enabled: false}), do: state
  defp maybe_schedule_timer(state, %Schedule{next_at: nil}), do: state

  defp maybe_schedule_timer(state, %Schedule{} = schedule) do
    now = state.clock.()
    delay = max(DateTime.diff(schedule.next_at, now, :millisecond), 0)
    timer = Process.send_after(self(), {:schedule_due, schedule.id, schedule.next_at}, delay)
    put_in(state, [:timers, schedule.id], timer)
  end

  defp cancel_timer(state, schedule_id) do
    case Map.pop(state.timers, schedule_id) do
      {nil, timers} ->
        %{state | timers: timers}

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end

  defp due?(%Schedule{enabled: true, next_at: %DateTime{} = next_at}, now) do
    DateTime.compare(next_at, now) in [:lt, :eq]
  end

  defp due?(_schedule, _now), do: false

  defp max_datetime(first, second) do
    if DateTime.compare(first, second) == :lt, do: second, else: first
  end

  defp misfired?(%Schedule{next_at: %DateTime{} = next_at, misfire_grace_ms: grace}, now) do
    DateTime.diff(now, next_at, :millisecond) > grace
  end

  defp misfired?(_schedule, _now), do: false

  defp active_run?(schedule, state) do
    state = refresh_active_runs(state, schedule.id)
    {not empty_active_runs?(state, schedule.id), state}
  end

  defp maybe_cancel_active_runs(%Schedule{cancellation: :future_only}, state), do: state

  defp maybe_cancel_active_runs(schedule, state) do
    state = refresh_active_runs(state, schedule.id)

    state.active_runs
    |> Map.get(schedule.id, MapSet.new())
    |> Enum.each(&state.background.stop(state.runner, &1))

    put_in(state, [:active_runs, schedule.id], MapSet.new())
  end

  defp put_active_run(state, schedule_id, run_id) do
    update_in(state, [:active_runs, schedule_id], fn
      nil -> MapSet.new([run_id])
      %MapSet{} = run_ids -> MapSet.put(run_ids, run_id)
    end)
  end

  defp delete_active_run(state, schedule_id, run_id) do
    update_in(state, [:active_runs, schedule_id], fn
      nil -> MapSet.new()
      %MapSet{} = run_ids -> MapSet.delete(run_ids, run_id)
    end)
  end

  defp empty_active_runs?(state, schedule_id) do
    state.active_runs
    |> Map.get(schedule_id, MapSet.new())
    |> MapSet.size()
    |> Kernel.==(0)
  end

  defp refresh_active_runs(state, schedule_id) do
    active =
      state.active_runs
      |> Map.get(schedule_id, MapSet.new())
      |> Enum.reduce(MapSet.new(), fn run_id, active ->
        case state.background.get(state.runner, run_id) do
          {:ok, %Run{} = run} -> if Run.terminal?(run), do: active, else: MapSet.put(active, run_id)
          {:error, _reason} -> active
        end
      end)

    put_in(state, [:active_runs, schedule_id], active)
  end

  defp rebuild_active_runs(state) do
    active_runs =
      Map.new(state.history, fn {schedule_id, triggers} ->
        candidates =
          triggers
          |> Enum.reduce(MapSet.new(), fn
            %Trigger{status: :started, run_id: run_id}, run_ids when is_binary(run_id) ->
              MapSet.put(run_ids, run_id)

            _trigger, run_ids ->
              run_ids
          end)

        active =
          Enum.reduce(candidates, MapSet.new(), fn run_id, active ->
            case state.background.get(state.runner, run_id) do
              {:ok, %Run{} = run} -> if Run.terminal?(run), do: active, else: MapSet.put(active, run_id)
              {:error, _reason} -> active
            end
          end)

        {schedule_id, active}
      end)

    %{state | active_runs: active_runs}
  end
end
