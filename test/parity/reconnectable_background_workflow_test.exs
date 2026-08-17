defmodule Jidoka.Parity.ReconnectableBackgroundWorkflowTest do
  use Jidoka.ParityCase, parity: :reconnectable_background_workflow

  alias Jidoka.Workflow.Background
  alias Jidoka.Workflow.Run
  alias Runic.Runner.Store.ETS

  import ExUnit.CaptureLog

  @moduletag :w07

  @runner __MODULE__.Runner
  @restart_timeout_ms 1_000

  defmodule Functions do
    @moduledoc false

    def prepare(%{value: value}, _context), do: {:ok, %{value: value}}

    def block(%{value: value}, context) do
      observer = Jidoka.Context.get_runtime(context, :observer)
      send(observer, {:background_step_started, self()})

      receive do
        :release_background_step -> {:ok, %{value: value * 2}}
      after
        2_000 -> {:error, :background_step_not_released}
      end
    end
  end

  defmodule DurableWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id :reconnectable_background_workflow
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

  test "reconnects by stable ID and recovers an in-flight worker from events" do
    parent = self()

    first_observer =
      spawn(fn ->
        receive do
          message -> send(parent, message)
        end
      end)

    assert {:ok, "run_workflow_1"} =
             Background.submit(@runner, DurableWorkflow, %{value: 21},
               run_id: "run_workflow_1",
               context: Jidoka.Context.from_data!(%{}, runtime: %{observer: first_observer})
             )

    assert_receive {:background_step_started, first_task}, 1_000

    assert {:ok, %Run{id: "run_workflow_1", status: :running}} =
             Background.get(@runner, "run_workflow_1")

    assert {:ok, events_before_crash} = Background.events(@runner, "run_workflow_1")
    assert events_before_crash != []
    assert Enum.map(events_before_crash, & &1.sequence) == Enum.to_list(1..length(events_before_crash))
    refute inspect(events_before_crash) =~ inspect(self())

    capture_log(fn ->
      runner = Process.whereis(@runner)
      worker_supervisor = Process.whereis(Module.concat(@runner, WorkerSupervisor))
      runner_monitor = Process.monitor(runner)
      task_monitor = Process.monitor(first_task)
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :killed}, 1_000
      assert_receive {:DOWN, ^task_monitor, :process, ^first_task, _reason}, 1_000
      wait_for_runner_restart(runner, worker_supervisor)
    end)

    assert {:ok,
            %Run{
              status: :recoverable,
              workflow_id: "reconnectable_background_workflow",
              event_count: event_count
            }} =
             Background.get(@runner, "run_workflow_1")

    assert event_count > 0

    capture_log(fn ->
      assert {:ok, _worker} =
               Background.recover(@runner, "run_workflow_1",
                 context: Jidoka.Context.from_data!(%{}, runtime: %{observer: self()})
               )

      assert_receive {:background_step_started, recovered_task}, 1_000
      send(recovered_task, :release_background_step)
    end)

    assert {:ok, %Run{} = finished} =
             Background.await(@runner, "run_workflow_1", timeout: 2_000)

    assert finished.status == :completed
    assert finished.workflow_id == "reconnectable_background_workflow"
    assert finished.output == %{value: 42}
    assert finished.outcomes.prepared.status == :ok
    assert finished.outcomes.blocked.status == :ok
    assert finished.event_count > event_count

    assert :ok = Background.stop(@runner, "run_workflow_1")

    assert {:ok, %Run{status: :completed, output: %{value: 42}}} =
             Background.get(@runner, "run_workflow_1")

    assert {:error, {:background_run_not_recoverable, :completed}} =
             Background.recover(@runner, "run_workflow_1")
  end

  defp wait_for_runner_restart(previous, previous_worker_supervisor) do
    deadline = System.monotonic_time(:millisecond) + @restart_timeout_ms
    wait_for_runner_restart(previous, previous_worker_supervisor, deadline)
  end

  defp wait_for_runner_restart(previous, previous_worker_supervisor, deadline) do
    runner = Process.whereis(@runner)
    worker_supervisor = Process.whereis(Module.concat(@runner, WorkerSupervisor))

    if is_pid(runner) and runner != previous and is_pid(worker_supervisor) and
         worker_supervisor != previous_worker_supervisor do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("""
        runner did not restart within #{@restart_timeout_ms}ms
        previous runner: #{inspect(previous)}
        last runner: #{inspect(runner)}
        previous worker supervisor: #{inspect(previous_worker_supervisor)}
        last worker supervisor: #{inspect(worker_supervisor)}
        """)
      end

      Process.sleep(min(5, deadline - now))
      wait_for_runner_restart(previous, previous_worker_supervisor, deadline)
    end
  end
end
