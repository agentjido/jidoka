defmodule Jidoka.WorkflowLifecycleTest do
  use ExUnit.Case, async: false

  alias Jidoka.Workflow
  alias Jidoka.Workflow.{Background, Run, Schedule, Scheduler, Snapshot}
  alias Jidoka.Workflow.Loop.Cursor
  alias Jidoka.Workflow.Schedule.Trigger

  @runner __MODULE__.Runner
  @scheduler __MODULE__.Scheduler
  @now ~U[2026-08-01 12:00:00Z]

  defmodule Functions do
    @moduledoc false

    def complete(%{value: value}, _context), do: {:ok, %{value: value * 2}}

    def drain(%{state: %{pending: []} = state}, _context), do: {:halt, state}

    def drain(%{state: state}, _context) do
      [item | pending] = state.pending
      {:cont, %{pending: pending, processed: state.processed ++ [item]}}
    end

    def pause(%{state: state}, context) do
      if Jidoka.Context.get(context, :pause), do: {:suspend, state}, else: {:halt, state}
    end

    def continue(%{state: state}, _context), do: {:cont, state}
  end

  defmodule LoopWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :lifecycle_loop
      input Zoi.object(%{items: Zoi.array(Zoi.integer())})
    end

    steps do
      loop :drain,
        initial: %{pending: input(:items), processed: value([])},
        using: {Functions, :drain, 2},
        input: %{state: loop_state()},
        max_iterations: 4
    end

    output from(:drain)
  end

  defmodule SuspendingWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :lifecycle_suspending_loop
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      loop :pause,
        initial: %{value: input(:value)},
        using: {Functions, :pause, 2},
        input: %{state: loop_state()},
        max_iterations: 2
    end

    output from(:pause)
  end

  defmodule ExhaustedWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :lifecycle_exhausted_loop
      input Zoi.object(%{})
    end

    steps do
      loop :continue,
        initial: value(%{}),
        using: {Functions, :continue, 2},
        input: %{state: loop_state()},
        max_iterations: 1
    end

    output from(:continue)
  end

  defmodule LifecycleWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :lifecycle_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :complete, {Functions, :complete, 2}, input: %{value: input(:value)}
    end

    output from(:complete)
  end

  defmodule CallbackWorkflow do
    @moduledoc false

    use Jidoka.Workflow,
      id: :callback_lifecycle,
      parameters_schema: %{"type" => "object"}

    @impl true
    def run(_input, _context), do: {:ok, %{done: true}}
  end

  defmodule BackgroundProbe do
    @moduledoc false

    alias Jidoka.Workflow.Run

    def get(probe, run_id) do
      Elixir.Agent.get_and_update(probe, fn state ->
        result =
          case Map.fetch(state.runs, run_id) do
            {:ok, {:error, reason}} ->
              {:error, reason}

            {:ok, status} ->
              {:ok, %Run{id: run_id, workflow_id: "probe", status: status, outcomes: %{}, event_count: 0}}

            :error ->
              {:error, :not_found}
          end

        {result, %{state | gets: state.gets ++ [run_id]}}
      end)
    end

    def stop(probe, run_id) do
      Elixir.Agent.update(probe, &%{&1 | stops: &1.stops ++ [run_id]})
      :ok
    end
  end

  setup do
    start_supervised!({Background, name: @runner})

    start_supervised!({Scheduler, name: @scheduler, runner: @runner, auto_schedule: false, clock: fn -> @now end})

    :ok
  end

  test "workflow snapshots reject runtime values and unsupported input" do
    cursor = Cursor.new!(:work, %{pending: [1]}, 3)

    snapshot = %Snapshot{
      schema_version: Snapshot.schema_version(),
      workflow: LifecycleWorkflow,
      workflow_id: "lifecycle_workflow",
      input: %{value: 1},
      context: %{},
      steps: %{},
      outcomes: %{work: %{status: :suspended, cursor: cursor}}
    }

    assert {:ok, binary} = Snapshot.serialize(snapshot)
    assert {:ok, ^snapshot} = Snapshot.deserialize(binary)

    unsupported = %{snapshot | schema_version: 99}

    assert {:error, {:unsupported_snapshot_version, 99}} =
             unsupported |> :erlang.term_to_binary() |> Snapshot.deserialize()

    non_portable = put_in(snapshot.outcomes.work.cursor.state, %{worker: self()})

    assert {:error, {:non_serializable_workflow_snapshot_value, _, :pid}} =
             Snapshot.serialize(non_portable)

    assert {:error, {:invalid_workflow_snapshot, :not_a_snapshot}} =
             :not_a_snapshot |> :erlang.term_to_binary() |> Snapshot.deserialize()

    assert {:error, {:invalid_workflow_snapshot, :not_binary}} =
             Snapshot.deserialize(:not_binary)

    assert {:error, {:snapshot_deserialize_failed, _exception}} = Snapshot.deserialize(<<1, 2, 3>>)
  end

  test "version one snapshots normalize one cursor and reject conflicts" do
    cursor = Cursor.new!(:work, %{pending: [1]}, 3)

    current = %Snapshot{
      schema_version: Snapshot.schema_version(),
      workflow: LifecycleWorkflow,
      workflow_id: "lifecycle_workflow",
      input: %{value: 1},
      context: %{},
      steps: %{},
      outcomes: %{work: %{status: :suspended, cursor: cursor}}
    }

    legacy = current |> Map.put(:schema_version, 1) |> Map.put(:loop_cursor, cursor)

    assert {:ok, upgraded} = legacy |> :erlang.term_to_binary() |> Snapshot.deserialize()
    assert upgraded.schema_version == Snapshot.schema_version()
    assert {:ok, ^cursor} = Snapshot.cursor(upgraded)
    refute Map.has_key?(upgraded, :loop_cursor)

    conflicting_cursor = Cursor.new!(:other, %{pending: []}, 3)
    conflicting = Map.put(legacy, :loop_cursor, conflicting_cursor)

    assert {:error, {:workflow_snapshot_cursor_conflict, ^cursor, ^conflicting_cursor}} =
             conflicting |> :erlang.term_to_binary() |> Snapshot.deserialize()

    duplicate =
      put_in(current.outcomes[:other], %{status: :suspended, cursor: conflicting_cursor})

    assert {:error, {:multiple_workflow_suspensions, [:other, :work]}} =
             Snapshot.serialize(duplicate)
  end

  test "bounded loops complete, suspend and resume, and stop at their exact limit" do
    assert {:ok, result} = Workflow.run(LoopWorkflow, %{items: [1, 2]})
    assert result.value == %{pending: [], processed: [1, 2]}
    assert Enum.map(result.iterations, & &1.decision) == [:cont, :cont, :halt]

    assert {:hibernate, snapshot} =
             Workflow.run(SuspendingWorkflow, %{value: 7}, context: %{pause: true})

    refute Map.has_key?(snapshot, :loop_cursor)
    assert %{pause: %{status: :suspended}} = snapshot.outcomes
    assert {:ok, cursor} = Snapshot.cursor(snapshot)
    assert cursor.next_iteration == 1
    assert {:ok, resumed} = Workflow.resume(snapshot, context: %{pause: false})
    assert resumed.value == %{value: 7}

    assert {:error, error} = Workflow.run(ExhaustedWorkflow, %{})
    assert %{details: %{cause: {:loop_limit_exceeded, cursor}}} = error
    assert cursor.next_iteration == 1
  end

  test "schedule contracts validate policy and advance one-time and cron triggers" do
    assert Schedule.overlap_policies() == [:skip, :allow]
    assert Schedule.misfire_policies() == [:skip, :run_once]
    assert Schedule.cancellation_policies() == [:future_only, :future_and_active]

    assert {:ok, one_time} =
             Schedule.new(
               %{
                 "id" => "one_time",
                 "workflow" => LifecycleWorkflow,
                 "input" => %{value: 1},
                 "trigger" => {:at, @now},
                 "enabled" => true
               },
               now: @now
             )

    assert {:ok, disabled} = Schedule.advance(one_time, @now)
    refute disabled.enabled
    assert disabled.next_at == nil

    assert {:ok, cron} =
             Schedule.new(
               [
                 id: "cron",
                 workflow: LifecycleWorkflow,
                 input: %{value: 1},
                 trigger: {:cron, "*/5 * * * *"},
                 timezone: "America/Chicago"
               ],
               now: @now
             )

    assert cron.next_at.time_zone == "America/Chicago"
    assert {:ok, advanced} = Schedule.advance(cron, cron.next_at)
    assert DateTime.compare(advanced.next_at, cron.next_at) == :gt

    assert {:error, {:invalid_schedule_attributes, [1]}} = Schedule.new([1])

    assert {:error, {:invalid_schedule_attributes, :invalid}} = Schedule.new(:invalid)

    assert {:error, {:invalid_schedule_id, ""}} =
             Schedule.new(%{id: "", workflow: LifecycleWorkflow, trigger: {:at, @now}})

    assert {:error, {:scheduled_workflow_requires_dsl, "callback_lifecycle"}} =
             Schedule.new(%{workflow: CallbackWorkflow, trigger: {:at, @now}})

    assert {:error, {:invalid_schedule_input, [1]}} =
             Schedule.new(%{workflow: LifecycleWorkflow, input: [1], trigger: {:at, @now}})

    assert {:error, {:invalid_schedule_trigger, :daily}} =
             Schedule.new(%{workflow: LifecycleWorkflow, trigger: :daily})

    assert {:error, {:invalid_schedule_timezone, "Invalid/Zone", _reason}} =
             Schedule.new(%{workflow: LifecycleWorkflow, trigger: {:at, @now}, timezone: "Invalid/Zone"})

    assert {:error, {:invalid_schedule_policy, :overlap, :queue}} =
             Schedule.new(%{workflow: LifecycleWorkflow, trigger: {:at, @now}, overlap: :queue})

    assert {:error, :scheduled_run_id_is_generated} =
             Schedule.new(%{
               workflow: LifecycleWorkflow,
               trigger: {:at, @now},
               run_opts: [run_id: "fixed"]
             })

    assert {:error, {:invalid_schedule_misfire_grace, -1}} =
             Schedule.new(%{
               workflow: LifecycleWorkflow,
               trigger: {:at, @now},
               misfire_grace_ms: -1
             })

    assert {:error, {:invalid_schedule_run_opts, [1]}} =
             Schedule.new(%{workflow: LifecycleWorkflow, trigger: {:at, @now}, run_opts: [1]})

    assert {:error, {:invalid_schedule_enabled, :yes}} =
             Schedule.new(%{workflow: LifecycleWorkflow, trigger: {:at, @now}, enabled: :yes})
  end

  test "background and scheduler APIs keep stable lookup and manual-trigger behavior" do
    assert :completed in Run.statuses()

    assert Run.terminal?(%Run{
             id: "done",
             workflow_id: "test",
             status: :completed,
             outcomes: %{},
             event_count: 0
           })

    refute Run.terminal?(%Run{
             id: "active",
             workflow_id: "test",
             status: :running,
             outcomes: %{},
             event_count: 0
           })

    assert {:error, :not_found} = Background.get(@runner, "missing")
    assert {:error, :not_found} = Background.events(@runner, "missing")

    assert {:error, {:invalid_background_run_id, ""}} =
             Background.submit(@runner, LifecycleWorkflow, %{value: 1}, run_id: "")

    assert {:error, {:background_workflow_requires_dsl, "callback_lifecycle"}} =
             Background.submit(@runner, CallbackWorkflow, %{})

    assert Scheduler.list(@scheduler) == []
    assert Scheduler.history(@scheduler, "missing") == []
    assert {:error, :not_found} = Scheduler.get(@scheduler, "missing")
    assert {:error, :not_found} = Scheduler.cancel(@scheduler, "missing")

    due_at = DateTime.add(@now, 60, :second)

    assert {:ok, schedule} =
             Scheduler.add(@scheduler, %{
               id: "manual",
               workflow: LifecycleWorkflow,
               input: %{value: 21},
               trigger: {:at, due_at}
             })

    assert {:error, {:schedule_already_exists, "manual"}} =
             Scheduler.add(@scheduler, %{
               id: "manual",
               workflow: LifecycleWorkflow,
               trigger: {:at, due_at}
             })

    assert [^schedule] = Scheduler.list(@scheduler)
    assert {:ok, trigger} = Scheduler.trigger(@scheduler, schedule.id, @now)
    assert trigger.status == :started
    assert trigger.due_at == due_at

    assert {:ok, %Run{status: :completed, output: %{value: 42}}} =
             Background.await(@runner, trigger.run_id)

    assert eventually(fn -> active_run_ids(@scheduler, schedule.id) == MapSet.new() end)

    assert {:ok, unchanged} = Scheduler.get(@scheduler, schedule.id)
    assert unchanged.next_at == due_at
    assert [^trigger] = Scheduler.history(@scheduler, schedule.id)

    assert {:ok, cancelled} = Scheduler.cancel(@scheduler, schedule.id)
    refute cancelled.enabled

    assert {:ok, cancelled_trigger} = Scheduler.trigger(@scheduler, schedule.id, @now)
    assert cancelled_trigger.status == :cancelled
    assert cancelled_trigger.reason == :schedule_disabled
  end

  test "active lookup and cancellation do not scan completed trigger history" do
    {:ok, probe} =
      Elixir.Agent.start_link(fn ->
        %{runs: %{"active-run" => :running}, gets: [], stops: []}
      end)

    scheduler = __MODULE__.IndexedScheduler

    start_supervised!(
      {Scheduler,
       name: scheduler, runner: probe, background: BackgroundProbe, auto_schedule: false, clock: fn -> @now end}
    )

    assert {:ok, schedule} =
             Scheduler.add(scheduler, %{
               id: "indexed",
               workflow: LifecycleWorkflow,
               input: %{value: 1},
               trigger: {:at, @now},
               overlap: :skip,
               cancellation: :future_and_active
             })

    completed_history =
      Enum.map(1..1_000, fn index ->
        %Trigger{
          schedule_id: schedule.id,
          due_at: @now,
          triggered_at: @now,
          status: :started,
          run_id: "completed-#{index}",
          reason: nil,
          attempts: 1
        }
      end)

    :sys.replace_state(scheduler, fn state ->
      %{
        state
        | history: %{schedule.id => completed_history},
          active_runs: %{schedule.id => MapSet.new(["active-run"])}
      }
    end)

    assert {:ok, %Trigger{status: :skipped, reason: :overlap}} =
             Scheduler.trigger(scheduler, schedule.id, @now)

    assert {:ok, _cancelled} = Scheduler.cancel(scheduler, schedule.id)

    assert %{gets: ["active-run", "active-run"], stops: ["active-run"]} =
             Elixir.Agent.get(probe, & &1)

    assert active_run_ids(scheduler, schedule.id) == MapSet.new()
    assert length(Scheduler.history(scheduler, schedule.id)) == 1_001
  end

  test "active lookup errors keep overlap protection closed" do
    {:ok, probe} =
      Elixir.Agent.start_link(fn ->
        %{runs: %{"uncertain-run" => {:error, :backend_unavailable}}, gets: [], stops: []}
      end)

    scheduler = __MODULE__.UncertainScheduler

    start_supervised!(
      {Scheduler,
       name: scheduler, runner: probe, background: BackgroundProbe, auto_schedule: false, clock: fn -> @now end}
    )

    assert {:ok, schedule} =
             Scheduler.add(scheduler, %{
               id: "uncertain",
               workflow: LifecycleWorkflow,
               input: %{value: 1},
               trigger: {:at, @now},
               overlap: :skip
             })

    :sys.replace_state(scheduler, fn state ->
      %{state | active_runs: %{schedule.id => MapSet.new(["uncertain-run"])}}
    end)

    assert {:ok, %Trigger{status: :skipped, reason: :overlap}} =
             Scheduler.trigger(scheduler, schedule.id, @now)

    assert active_run_ids(scheduler, schedule.id) == MapSet.new(["uncertain-run"])
  end

  test "legacy scheduler state rebuilds only nonterminal active runs" do
    {:ok, probe} =
      Elixir.Agent.start_link(fn ->
        %{runs: %{"active-run" => :running, "finished-run" => :completed}, gets: [], stops: []}
      end)

    history = %{
      "recovered" => [
        trigger("recovered", "finished-run"),
        trigger("recovered", "active-run")
      ]
    }

    legacy_state = %{
      runner: probe,
      background: BackgroundProbe,
      schedules: %{},
      history: history,
      timers: %{},
      clock: fn -> @now end,
      auto_schedule: false,
      notification_target: self()
    }

    assert {:ok, recovered} = Scheduler.code_change(:legacy, legacy_state, nil)
    assert recovered.active_runs == %{"recovered" => MapSet.new(["active-run"])}

    assert %{gets: gets, stops: []} = Elixir.Agent.get(probe, & &1)
    assert Enum.sort(gets) == ["active-run", "finished-run"]
  end

  defp active_run_ids(scheduler, schedule_id) do
    scheduler
    |> :sys.get_state()
    |> Map.fetch!(:active_runs)
    |> Map.get(schedule_id, MapSet.new())
  end

  defp trigger(schedule_id, run_id) do
    %Trigger{
      schedule_id: schedule_id,
      due_at: @now,
      triggered_at: @now,
      status: :started,
      run_id: run_id,
      reason: nil,
      attempts: 1
    }
  end

  defp eventually(predicate, attempts \\ 50)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(2)
      eventually(predicate, attempts - 1)
    end
  end
end
