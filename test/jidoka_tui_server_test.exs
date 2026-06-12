defmodule Jidoka.TuiServerTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Artifact
  alias Jidoka.SessionServer
  alias Jidoka.TestAttemptExecutionAdapters.Success
  alias Jidoka.TestVerificationAdapters.Passed
  alias Jidoka.VerificationResult
  alias Jidoka.TuiServer
  alias Jidoka.TuiRenderer

  defmodule CancelSlowAdapter do
    @moduledoc false

    @behaviour Jidoka.AttemptExecution

    alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

    @impl true
    def execute(%AttemptSpec{} = _spec) do
      Process.sleep(200)

      {:ok,
       %AttemptOutput{
         status: :succeeded,
         progress: [],
         metadata: %{adapter: :cancel_slow}
       }}
    end
  end

  test "booted shell opens a new session and renders stable regions" do
    {:ok, pid} = TuiServer.start_link(poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    state = TuiServer.state(pid)
    render = TuiServer.render(pid)
    model = TuiServer.render_model(pid)

    assert state.mode == :attached
    assert is_binary(state.session_ref)
    assert is_list(state.activity_lines)
    assert is_list(state.focused_progress_lines)
    assert Map.has_key?(model, :status)
    assert Map.has_key?(model, :focused_run)
    assert Map.has_key?(model, :artifacts)
    assert Map.has_key?(model, :events)
    assert Map.has_key?(model, :input)
    assert String.contains?(render, "[status]")
    assert String.contains?(render, "[focused run]")
    assert String.contains?(render, "[artifacts]")
    assert String.contains?(render, "[event stream]")
    assert String.contains?(render, "[operator input]")

    on_exit(fn -> close_session(state.session_ref) end)
  end

  test "can attach to an existing session and load an initial snapshot" do
    session_id = unique_id("tui-existing")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-existing")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    state = TuiServer.state(pid)

    assert state.mode == :attached
    assert state.session_ref == session_id
    assert state.session_status == :initializing
  end

  test "missing sessions produce a recoverable shell state" do
    missing_session = unique_id("tui-missing")
    {:ok, pid} = TuiServer.start_link(session: missing_session, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    state = TuiServer.state(pid)
    render = TuiServer.render(pid)

    assert state.mode == :recoverable
    assert state.recoverable_reason == :missing
    assert String.contains?(render, "recoverable")
  end

  test "closed sessions render in a recoverable state" do
    session_id = unique_id("tui-closed")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-closed")
    on_exit(fn -> close_session(session_id) end)

    assert :ok = Agent.close(session_id)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    state = TuiServer.state(pid)

    assert state.mode == :recoverable
    assert state.recoverable_reason == :closed
    assert state.session_status == :closed
    assert state.session_ref == session_id
  end

  test "subscribes to session events and updates the view model from snapshots" do
    session_id = unique_id("tui-events")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-events")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run, attempt: attempt}} =
             Agent.submit(session_id, "tui event smoke", execution_adapter: Success)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.mode == :attached &&
                 state.active_run_id == run.id &&
                 Enum.any?(state.activity_lines, &String.contains?(&1, "run_submitted")) &&
                 Enum.any?(
                   state.focused_progress_lines,
                   &String.contains?(&1, "attempt_progress")
                 ) &&
                 not is_nil(state.session_ref)
             end)

    state = TuiServer.state(pid)
    model = TuiServer.render_model(pid)

    assert state.active_run_status in [:queued, :running, :awaiting_approval]
    assert model.focused_run.heading == "focused run"
    assert Enum.any?(model.focused_run.lines, &String.contains?(&1, "run_id=#{run.id}"))
    assert Enum.any?(model.focused_run.lines, &String.contains?(&1, "attempt_id=#{attempt.id}"))
    assert Enum.any?(model.events.lines, &String.contains?(&1, "attempt_progress"))
  end

  test "reconnect command reattaches to an existing session after restart" do
    session_id = unique_id("tui-reconnect")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-reconnect")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert TuiServer.state(pid).mode == :attached
    assert TuiServer.stop(pid) == :ok

    {:ok, pid} = TuiServer.start_link(poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert TuiServer.state(pid).mode == :recoverable
    assert :ok = TuiServer.command(pid, :reconnect, session_id)

    state = TuiServer.state(pid)
    assert state.mode == :attached
    assert state.session_ref == session_id
  end

  test "TUI lists available runs and focuses each run independently" do
    session_id = unique_id("tui-run-focus")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-run-focus")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run_a, attempt: attempt_a}} =
             Agent.submit(
               session_id,
               "first run for focus",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert {:ok, %{run: run_b, attempt: attempt_b}} =
             Agent.submit(
               session_id,
               "second run for focus",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    artifact_a = unique_id("artifact-a")
    artifact_b = unique_id("artifact-b")

    assert :ok =
             SessionServer.persist_attempt_artifacts(
               attempt_a.id,
               [%{id: artifact_a, type: :diff, status: :ready, location: "/tmp/#{artifact_a}"}]
             )

    assert :ok =
             SessionServer.persist_attempt_artifacts(
               attempt_b.id,
               [%{id: artifact_b, type: :diff, status: :ready, location: "/tmp/#{artifact_b}"}]
             )

    assert :ok =
             await_session_activity_contains(
               pid,
               fn state ->
                 MapSet.new(state.available_runs || []) == MapSet.new([run_a.id, run_b.id])
               end
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id in [run_a.id, run_b.id]
             end)

    assert :ok = TuiServer.command(pid, :focus_run, run_a.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run_a.id &&
                 state.active_attempt_id == attempt_a.id
             end)

    model = TuiServer.render_model(pid)

    assert Enum.any?(model.status.lines, &(&1 == "active_run_id=#{run_a.id}"))
    assert Enum.any?(model.events.lines, &String.contains?(&1, "run=#{run_a.id}"))
    assert Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=#{artifact_a}"))

    assert :ok = TuiServer.command(pid, :focus_run, run_b.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run_b.id &&
                 state.active_attempt_id == attempt_b.id
             end)

    model = TuiServer.render_model(pid)

    assert Enum.any?(model.status.lines, &(&1 == "active_run_id=#{run_b.id}"))
    assert Enum.any?(model.events.lines, &String.contains?(&1, "run=#{run_b.id}"))
    assert Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=#{artifact_b}"))
    refute Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=#{artifact_a}"))
  end

  test "reconnect keeps focused run when still available in session snapshot" do
    session_id = unique_id("tui-run-focus-reconnect")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-run-focus-reconnect")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run_a}} =
             Agent.submit(
               session_id,
               "run A for reconnect focus",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert {:ok, %{run: run_b}} =
             Agent.submit(
               session_id,
               "run B for reconnect focus",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert :ok =
             await_session_activity_contains(
               pid,
               fn state ->
                 MapSet.new(state.available_runs || []) == MapSet.new([run_a.id, run_b.id])
               end
             )

    assert :ok = TuiServer.command(pid, :focus_run, run_a.id)

    assert :ok =
             await_session_activity_contains(
               pid,
               fn state ->
                 state.active_run_id == run_a.id && state.active_run_status == :awaiting_approval
               end
             )

    assert :ok = TuiServer.command(pid, :reconnect, session_id)
    assert TuiServer.state(pid).active_run_id == run_a.id
  end

  test "control-state presentation reflects legal and illegal actions" do
    session_id = unique_id("tui-control-state")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-control-state")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "state check run",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_attempt_id != nil &&
                 state.active_attempt_status in [:running, :succeeded]
             end)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :awaiting_approval
             end)

    render = TuiServer.render_model(pid)

    assert Enum.any?(render.status.lines, &String.contains?(&1, "approve=legal"))
    assert Enum.any?(render.status.lines, &String.contains?(&1, "reject=legal"))
    assert Enum.any?(render.status.lines, &String.contains?(&1, "retry=illegal"))
  end

  test "interrupted run uses the interrupt command family through public runtime control path" do
    session_id = unique_id("tui-interrupt")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-interrupt")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "interrupt run",
               execution_adapter: CancelSlowAdapter
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status in [:running, :queued]
             end)

    state = TuiServer.state(pid)
    assert state.command_controls.interrupt == :legal
    assert :ok = TuiServer.command(pid, :interrupt, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :canceled
             end)
  end

  test "steer command routes through the same control surface as runtime controls" do
    session_id = unique_id("tui-steer")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-steer")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "steer run",
               execution_adapter: CancelSlowAdapter
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :running
             end)

    assert :ok = TuiServer.command(pid, :steer, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :canceled
             end)
  end

  test "approve command finalizes an awaiting approval run" do
    session_id = unique_id("tui-approve")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-approve")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "approve run",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :awaiting_approval
             end)

    assert :ok = TuiServer.command(pid, :approve, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :completed
             end)
  end

  test "reject command finalizes run as terminal failed for approval family" do
    session_id = unique_id("tui-reject")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-reject")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "reject run",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :awaiting_approval
             end)

    assert :ok = TuiServer.command(pid, :reject, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :failed and state.active_run_outcome == :terminal_failed
             end)
  end

  test "retry command starts a new attempt from retryable failure" do
    session_id = unique_id("tui-retry")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-retry")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "retry run",
               execution_adapter: Success,
               verification_adapter: Jidoka.TestVerificationAdapters.RetryableFailed
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :failed
             end)

    assert :ok = TuiServer.command(pid, :retry, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :awaiting_approval
             end)
  end

  test "cancel command stops a running attempt" do
    session_id = unique_id("tui-cancel")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-cancel")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(
               session_id,
               "cancel run",
               execution_adapter: CancelSlowAdapter
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status in [:running, :queued]
             end)

    assert :ok = TuiServer.command(pid, :cancel, run.id)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_status == :canceled
             end)
  end

  test "command failures are surfaced in status output and state" do
    session_id = unique_id("tui-failure")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-failure")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run}} =
             Agent.submit(session_id, "failure run", execution_adapter: Success)

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status in [:queued, :running]
             end)

    assert {:error, {:command_not_allowed, :approve}} = TuiServer.command(pid, :approve, run.id)

    assert TuiServer.state(pid).last_error == {:command_not_allowed, :approve}

    assert Enum.any?(
             TuiServer.render_model(pid).status.lines,
             &String.contains?(&1, "command_error={:command_not_allowed, :approve}")
           )
  end

  test "status line summarizes session, run, attempt, and lease identity" do
    state = %TuiServer.State{
      session_ref: "session-status",
      session_status: :running,
      active_run_id: "run-status",
      active_run_status: :queued,
      active_attempt_id: "attempt-status",
      active_attempt_status: :succeeded,
      active_lease_id: "lease-status",
      active_lease_workspace_path: "/tmp/lease-status",
      active_run_task: "status summary",
      active_run_attempt_count: 1,
      active_attempt_number: 1,
      focused_artifacts: %{diff: [], command_log: [], verifier_report: []},
      active_verification_result: nil,
      activity_lines: [],
      focused_progress_lines: [],
      input_buffer: ""
    }

    model = TuiRenderer.render_model(state)

    assert Enum.any?(
             model.status.lines,
             &(&1 == "summary=session=running run=queued attempt=succeeded lease=lease-status")
           )

    assert Enum.any?(model.status.lines, &(&1 == "environment_lease=lease-status"))
  end

  test "artifact inspection renders empty artifact categories safely" do
    state = %TuiServer.State{
      focused_artifacts: %{diff: [], command_log: [], verifier_report: [], prompt_report: []},
      active_verification_result: nil,
      activity_lines: [],
      focused_progress_lines: [],
      input_buffer: ""
    }

    model = TuiRenderer.render_model(state)

    assert model.artifacts.lines == [
             "diff:",
             "  <none>",
             "log:",
             "  <none>",
             "verifier report:",
             "  <none>",
             "prompt report:",
             "  <none>"
           ]
  end

  test "artifact inspection summarizes populated artifact types and verifier results" do
    {:ok, diff} =
      Artifact.new(
        id: "artifact-diff",
        attempt_id: "attempt-abc",
        status: :ready,
        type: :diff,
        location: "/tmp/diff.patch"
      )

    {:ok, command_log} =
      Artifact.new(
        id: "artifact-log",
        attempt_id: "attempt-abc",
        status: :ready,
        type: :command_log,
        location: "/tmp/command.log"
      )

    {:ok, verifier_report} =
      Artifact.new(
        id: "artifact-verifier",
        attempt_id: "attempt-abc",
        status: :ready,
        type: :verifier_report,
        location: "/tmp/verifier.json"
      )

    {:ok, verification} =
      VerificationResult.new(
        id: "verification-status",
        attempt_id: "attempt-abc",
        status: :passed,
        outcome_summary: %{checks: [:passed]}
      )

    state = %TuiServer.State{
      active_run_id: "run-abc",
      active_run_status: :awaiting_approval,
      active_attempt_id: "attempt-abc",
      active_attempt_status: :succeeded,
      active_run_task: "artifacts and verifier",
      active_run_attempt_count: 1,
      active_attempt_number: 1,
      focused_artifacts: %{
        diff: [diff],
        command_log: [command_log],
        verifier_report: [verifier_report]
      },
      active_verification_result: verification,
      activity_lines: [],
      focused_progress_lines: [],
      input_buffer: ""
    }

    model = TuiRenderer.render_model(state)

    assert Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=artifact-diff"))
    assert Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=artifact-log"))
    assert Enum.any?(model.artifacts.lines, &String.contains?(&1, "id=artifact-verifier"))
    assert Enum.any?(model.focused_run.lines, &String.contains?(&1, "verifier_status=:passed"))
  end

  test "verification result appears when run verification completes" do
    session_id = unique_id("tui-verification")
    assert {:ok, ^session_id} = Agent.open(id: session_id, cwd: "/tmp/tui-verification")
    on_exit(fn -> close_session(session_id) end)

    {:ok, pid} = TuiServer.start_link(session: session_id, poll_interval: 0)
    on_exit(fn -> safe_stop_tui(pid) end)

    assert {:ok, %{run: run, lease: lease}} =
             Agent.submit(
               session_id,
               "verify result should be visible",
               execution_adapter: Success,
               verification_adapter: Passed
             )

    assert :ok =
             await_session_activity_contains(pid, fn state ->
               state.active_run_id == run.id && state.active_run_status == :awaiting_approval
             end)

    state = TuiServer.state(pid)
    model = TuiServer.render_model(pid)

    assert state.active_lease_id == lease.id
    assert Enum.any?(model.focused_run.lines, &String.contains?(&1, "verifier_status=:passed"))
    assert Enum.any?(model.status.lines, &String.contains?(&1, "summary=session="))
    assert Enum.any?(model.status.lines, &String.contains?(&1, "lease=#{lease.id}"))
  end

  defp await_session_activity_contains(pid, fun) do
    await_session_activity_contains(pid, fun, 50)
  end

  defp await_session_activity_contains(_pid, _fun, 0),
    do: flunk("did not receive expected TUI state")

  defp await_session_activity_contains(pid, fun, attempts_left) when attempts_left > 0 do
    TuiServer.refresh(pid)

    state = TuiServer.state(pid)

    if fun.(state) do
      :ok
    else
      Process.sleep(20)
      await_session_activity_contains(pid, fun, attempts_left - 1)
    end
  end

  defp close_session(session_id) do
    case Agent.close(session_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      _ -> :ok
    end
  end

  defp safe_stop_tui(pid) do
    if Process.alive?(pid) do
      TuiServer.stop(pid)
    end
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp unique_id(prefix) do
    "#{prefix}-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
