defmodule Jidoka.Parity.ScheduledWorkflowRunsTest do
  use Jidoka.ParityCase, parity: :scheduled_workflow_runs

  alias Jidoka.Workflow.{Background, Run, Scheduler}
  alias Runic.Runner.Store.ETS

  @moduletag :w08

  @runner __MODULE__.Runner
  @scheduler __MODULE__.Scheduler
  @now ~U[2026-08-01 12:00:00Z]

  defmodule Functions do
    @moduledoc false

    def complete(%{value: value}, _context), do: {:ok, %{value: value * 2}}

    def block(%{value: value}, context) do
      observer = Jidoka.Context.get_runtime(context, :observer)
      send(observer, {:scheduled_workflow_started, self()})

      receive do
        :release_scheduled_workflow -> {:ok, %{value: value}}
      after
        2_000 -> {:error, :scheduled_workflow_not_released}
      end
    end
  end

  defmodule ImmediateWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :scheduled_immediate_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :complete, {Functions, :complete, 2}, input: %{value: input(:value)}
    end

    output from(:complete)
  end

  defmodule BlockingWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :scheduled_blocking_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :block, {Functions, :block, 2}, input: %{value: input(:value)}
    end

    output from(:block)
  end

  setup do
    start_supervised!({ETS, runner_name: @runner})
    start_supervised!({Background, name: @runner, store: ETS, store_opts: []})

    start_supervised!({Scheduler, name: @scheduler, runner: @runner, auto_schedule: false, clock: fn -> @now end})

    :ok
  end

  test "runs one-time misfires and records normal reconnectable run evidence" do
    due_at = DateTime.add(@now, -60, :second)

    assert {:ok, schedule} =
             Scheduler.add(@scheduler, %{
               id: "daily_once",
               workflow: ImmediateWorkflow,
               input: %{value: 21},
               trigger: {:at, due_at},
               timezone: "Etc/UTC",
               overlap: :skip,
               misfire: :run_once,
               retry: [max_attempts: 2],
               cancellation: :future_only
             })

    assert schedule.next_at == due_at
    assert [trigger] = Scheduler.trigger_due(@scheduler, @now)
    assert trigger.status == :started
    assert trigger.attempts == 1
    assert is_binary(trigger.run_id)

    assert {:ok, %Run{status: :completed, output: %{value: 42}}} =
             Background.await(@runner, trigger.run_id, timeout: 2_000)

    assert [^trigger] = Scheduler.history(@scheduler, "daily_once")
    assert {:ok, disabled} = Scheduler.get(@scheduler, "daily_once")
    refute disabled.enabled

    assert {:ok, _schedule} =
             Scheduler.add(@scheduler, %{
               id: "skip_misfire",
               workflow: ImmediateWorkflow,
               input: %{value: 1},
               trigger: {:at, due_at},
               misfire: :skip
             })

    assert [skipped] = Scheduler.trigger_due(@scheduler, @now)
    assert skipped.status == :skipped
    assert skipped.reason == :misfire
    assert skipped.run_id == nil
  end

  test "validates timezone cron, skips overlap, and applies cancellation policy" do
    assert {:ok, cron_schedule} =
             Scheduler.add(@scheduler, %{
               id: "recurring_work",
               workflow: BlockingWorkflow,
               input: %{value: 7},
               trigger: {:cron, "*/5 * * * *"},
               timezone: "America/Chicago",
               overlap: :skip,
               misfire: :run_once,
               cancellation: :future_and_active,
               retry: [max_attempts: 1],
               run_opts: [
                 context: Jidoka.Context.from_data!(%{}, runtime: %{observer: self()})
               ]
             })

    assert cron_schedule.next_at.time_zone == "America/Chicago"
    assert DateTime.compare(cron_schedule.next_at, @now) == :gt
    assert {cron_schedule.next_at.hour, cron_schedule.next_at.minute} == {7, 5}

    assert {:ok, started} = Scheduler.trigger(@scheduler, "recurring_work", @now)
    assert started.status == :started
    assert_receive {:scheduled_workflow_started, worker}, 1_000

    assert {:ok, skipped} = Scheduler.trigger(@scheduler, "recurring_work", @now)
    assert skipped.status == :skipped
    assert skipped.reason == :overlap

    worker_monitor = Process.monitor(worker)
    assert {:ok, cancelled} = Scheduler.cancel(@scheduler, "recurring_work")
    refute cancelled.enabled
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000

    assert Enum.map(Scheduler.history(@scheduler, "recurring_work"), & &1.status) == [
             :started,
             :skipped
           ]
  end

  test "advances a recurring misfire past now and retries failed run submission" do
    assert {:ok, recurring} =
             Scheduler.add(@scheduler, %{
               "id" => "late_recurring_work",
               "workflow" => ImmediateWorkflow,
               "input" => %{value: 2},
               "trigger" => {:cron, "*/5 * * * *"},
               "timezone" => "Etc/UTC",
               "misfire" => :run_once,
               "misfire_grace_ms" => 0
             })

    late_now = DateTime.add(recurring.next_at, 3_600, :second)
    assert [started] = Scheduler.trigger_due(@scheduler, late_now)
    assert started.status == :started
    assert {:ok, %Run{status: :completed}} = Background.await(@runner, started.run_id)

    assert {:ok, advanced} = Scheduler.get(@scheduler, recurring.id)
    assert DateTime.compare(advanced.next_at, late_now) == :gt

    missing_runner = __MODULE__.MissingRunner
    failed_scheduler = __MODULE__.FailedScheduler

    start_supervised!(
      {Scheduler, name: failed_scheduler, runner: missing_runner, auto_schedule: false, clock: fn -> @now end}
    )

    assert {:ok, _schedule} =
             Scheduler.add(failed_scheduler, %{
               id: "failed_submission",
               workflow: ImmediateWorkflow,
               input: %{value: 1},
               trigger: {:at, @now},
               retry: [max_attempts: 2]
             })

    assert [failed] = Scheduler.trigger_due(failed_scheduler, @now)
    assert failed.status == :failed
    assert failed.attempts == 2
    assert failed.run_id == nil
  end
end
