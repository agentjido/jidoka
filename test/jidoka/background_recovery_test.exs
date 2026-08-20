defmodule Jidoka.BackgroundRecoveryTest do
  use ExUnit.Case, async: false

  alias Jidoka.Workflow.{Background, Run}
  alias Runic.Runner.Store.ETS

  import ExUnit.CaptureLog

  @runner __MODULE__.Runner

  defmodule Functions do
    @moduledoc false

    def prepare(%{value: value}, _context), do: {:ok, %{value: value}}

    def block(%{value: value}, context) do
      observer = Jidoka.Context.get_runtime(context, :observer)
      send(observer, {:background_step_started, self()})

      receive do
        :release -> {:ok, %{value: value * 2}}
      after
        2_000 -> {:error, :not_released}
      end
    end
  end

  defmodule DurableWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :background_recovery_test
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :prepared, {Functions, :prepare, 2}, input: %{value: input(:value)}
      function :blocked, {Functions, :block, 2}, input: %{value: from(:prepared, :value)}
    end

    output from(:blocked)
  end

  setup do
    start_supervised!({ETS, runner_name: @runner})
    start_supervised!({Background, name: @runner, store: ETS, store_opts: []})
    :ok
  end

  test "recovers an active workflow from its durable event stream" do
    assert {:ok, "run_recovery_test"} =
             Background.submit(@runner, DurableWorkflow, %{value: 21},
               run_id: "run_recovery_test",
               context: Jidoka.Context.from_data!(%{}, runtime: %{observer: self()})
             )

    assert_receive {:background_step_started, first_task}, 1_000
    assert {:ok, %Run{status: :running}} = Background.get(@runner, "run_recovery_test")
    assert {:ok, events} = Background.events(@runner, "run_recovery_test")
    assert events != []
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))

    capture_log(fn -> restart_runner(first_task) end)

    assert {:ok, %Run{status: :recoverable, event_count: event_count}} =
             Background.get(@runner, "run_recovery_test")

    assert event_count > 0

    capture_log(fn ->
      assert {:ok, _worker} =
               Background.recover(@runner, "run_recovery_test",
                 context: Jidoka.Context.from_data!(%{}, runtime: %{observer: self()})
               )

      assert_receive {:background_step_started, recovered_task}, 1_000
      send(recovered_task, :release)
    end)

    assert {:ok, %Run{status: :completed, output: %{value: 42}} = finished} =
             Background.await(@runner, "run_recovery_test", timeout: 2_000)

    assert finished.event_count > event_count
    assert :ok = Background.stop(@runner, "run_recovery_test")

    assert {:ok, %Run{status: :completed, output: %{value: 42}}} =
             Background.get(@runner, "run_recovery_test")

    assert {:error, {:background_run_not_recoverable, :completed}} =
             Background.recover(@runner, "run_recovery_test")
  end

  defp restart_runner(first_task) do
    runner = Process.whereis(@runner)
    worker_supervisor = Process.whereis(Module.concat(@runner, WorkerSupervisor))
    runner_monitor = Process.monitor(runner)
    task_monitor = Process.monitor(first_task)
    Process.exit(runner, :kill)
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :killed}, 1_000
    assert_receive {:DOWN, ^task_monitor, :process, ^first_task, _reason}, 1_000
    wait_for_runner(runner, worker_supervisor, System.monotonic_time(:millisecond) + 1_000)
  end

  defp wait_for_runner(previous, previous_worker_supervisor, deadline) do
    runner = Process.whereis(@runner)
    worker_supervisor = Process.whereis(Module.concat(@runner, WorkerSupervisor))

    if is_pid(runner) and runner != previous and is_pid(worker_supervisor) and
         worker_supervisor != previous_worker_supervisor do
      :ok
    else
      now = System.monotonic_time(:millisecond)
      assert now < deadline, "background runner did not restart"
      Process.sleep(min(5, deadline - now))
      wait_for_runner(previous, previous_worker_supervisor, deadline)
    end
  end
end
