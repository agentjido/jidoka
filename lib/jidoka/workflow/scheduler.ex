defmodule Jidoka.Workflow.Scheduler do
  @moduledoc """
  OTP scheduler that creates normal `Jidoka.Workflow.Background` runs.

  The scheduler owns schedule definitions, timers, and trigger history. Use an
  application supervisor for lifecycle ownership. Set `auto_schedule: false`
  in deterministic tests and call `trigger_due/2` with an explicit time.
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
       schedules: %{},
       history: %{},
       timers: %{},
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       auto_schedule: Keyword.get(opts, :auto_schedule, true)
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
  def handle_info({:schedule_due, schedule_id, due_at}, state) do
    case Map.fetch(state.schedules, schedule_id) do
      {:ok, %Schedule{next_at: ^due_at} = schedule} ->
        {_trigger, state} = fire(schedule, state.clock.(), state, true)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp fire(%Schedule{} = schedule, now, state, advance?) do
    due_at = schedule.next_at || now

    {trigger, state} =
      cond do
        not schedule.enabled ->
          record(schedule, due_at, now, :cancelled, nil, :schedule_disabled, 1, state)

        misfired?(schedule, now) and schedule.misfire == :skip ->
          record(schedule, due_at, now, :skipped, nil, :misfire, 1, state)

        schedule.overlap == :skip and active_run?(schedule, state) ->
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
    run_opts = Keyword.put(schedule.run_opts, :run_id, run_id)

    result =
      Retry.call(schedule.retry, fn ->
        Elixir.Agent.update(attempt_counter, &(&1 + 1))
        Background.submit(state.runner, schedule.workflow, schedule.input, run_opts)
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
    {trigger, %{state | history: history}}
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
    state.history
    |> Map.get(schedule.id, [])
    |> Enum.any?(fn
      %Trigger{run_id: run_id} when is_binary(run_id) ->
        case Background.get(state.runner, run_id) do
          {:ok, %Run{status: status}} -> status not in [:completed, :failed]
          {:error, _reason} -> false
        end

      _trigger ->
        false
    end)
  end

  defp maybe_cancel_active_runs(%Schedule{cancellation: :future_only}, state), do: state

  defp maybe_cancel_active_runs(schedule, state) do
    state.history
    |> Map.get(schedule.id, [])
    |> Enum.each(fn
      %Trigger{run_id: run_id} when is_binary(run_id) -> Background.stop(state.runner, run_id)
      _trigger -> :ok
    end)

    state
  end
end
