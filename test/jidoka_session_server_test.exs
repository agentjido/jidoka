defmodule JidokaSessionServerTest do
  use ExUnit.Case, async: false

  alias Jidoka.Attempt
  alias Jidoka.EnvironmentLease
  alias Jidoka.Run
  alias Jidoka.SessionServer

  defmodule CancelSlowAdapter do
    @moduledoc false
    @behaviour Jidoka.AttemptExecution

    alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

    @impl true
    def execute(%AttemptSpec{} = _spec) do
      Process.sleep(100)

      {:ok,
       %AttemptOutput{
         status: :succeeded,
         metadata: %{adapter: :cancel_slow},
         artifacts: []
       }}
    end
  end

  defmodule HangingAdapter do
    @moduledoc false
    @behaviour Jidoka.AttemptExecution

    alias Jidoka.AttemptExecution.{AttemptOutput, AttemptSpec}

    @impl true
    def execute(%AttemptSpec{}) do
      Process.sleep(500)

      {:ok,
       %AttemptOutput{
         status: :succeeded,
         metadata: %{adapter: :hanging},
         artifacts: []
       }}
    end
  end

  test "OTP boot tree includes session, attempt and event bus processes" do
    assert is_pid(Process.whereis(Jidoka.Registry))
    assert is_pid(Process.whereis(Jidoka.SessionSupervisor))
    assert is_pid(Process.whereis(Jidoka.AttemptSupervisor))
    assert is_pid(Process.whereis(Jidoka.Bus))
    assert is_pid(Process.whereis(Jidoka.SessionServer))
  end

  test "open bootstraps a durable session and provides session lookup" do
    session_id = unique_id("session-open")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-open")

    assert {:ok, %{session_ref: ^session_id, pid: session_pid}} = SessionServer.lookup(session_id)
    assert is_pid(session_pid)

    assert {:ok, %{session_ref: ^session_id, pid: ^session_pid}} =
             SessionServer.lookup(session_pid)

    assert {:ok, session_snapshot} = SessionServer.session_snapshot(session_id)
    assert session_snapshot.session.id == session_id
    assert is_list(session_snapshot.runs)

    assert :ok = SessionServer.close(session_id)
  end

  test "resume rebuilds session process state without changing durable identifiers" do
    session_id = unique_id("session-resume")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-resume")
    assert {:ok, %{pid: original_pid}} = SessionServer.lookup(session_id)

    assert {:ok, run} =
             Run.new(id: unique_id("run"), session_id: session_id, task: "resume run")

    assert :ok = SessionServer.persist_run(run)

    assert {:ok, attempt} =
             Attempt.new(id: unique_id("attempt"), run_id: run.id, attempt_number: 1)

    assert :ok = SessionServer.persist_attempt(attempt)

    assert {:ok, lease} =
             EnvironmentLease.new(
               id: unique_id("lease"),
               attempt_id: attempt.id,
               status: :active,
               workspace_path: "/tmp/resume-leased"
             )

    assert :ok = SessionServer.persist_environment_lease(lease)

    assert :ok = SessionServer.close(session_id)

    assert {:ok, ^session_id} = SessionServer.resume(session_id)
    assert {:ok, %{pid: resumed_pid}} = SessionServer.lookup(session_id)
    assert resumed_pid != original_pid

    assert {:ok, session_snapshot} = SessionServer.session_snapshot(session_id)
    assert session_snapshot.session.id == session_id
    assert Enum.any?(session_snapshot.runs, &(&1.id == run.id))

    assert {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    assert run_snapshot.run.id == run.id
    assert Enum.any?(run_snapshot.attempts, &(&1.id == attempt.id))
    assert Enum.any?(run_snapshot.leases, &(&1.id == lease.id))

    assert :ok = SessionServer.close(session_id)
  end

  test "submit creates durable run, initial attempt, and writable lease for the attempt" do
    session_id = unique_id("session-submit")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-submit")

    assert {:ok, %{run: run, attempt: attempt, lease: lease}} =
             SessionServer.submit(
               session_id,
               "implement login flow",
               task_pack: :coding
             )

    assert run.session_id == session_id
    assert run.task == "implement login flow"
    assert run.task_pack == :coding
    assert run.status == :queued
    assert attempt.run_id == run.id
    assert attempt.status == :pending
    assert attempt.attempt_number == 1
    assert lease.attempt_id == attempt.id
    assert lease.status == :active
    assert lease.mode == :exclusive
    assert lease.workspace_path =~ run.id
    assert lease.workspace_path =~ attempt.id
    assert lease.metadata.run_id == run.id
    assert lease.metadata.source_workspace_path == "/tmp/session-submit"

    assert {:ok, session_snapshot} = SessionServer.session_snapshot(session_id)
    assert Enum.find(session_snapshot.runs, &(&1.id == run.id))

    assert session_snapshot.runs
           |> Enum.find(&(&1.id == run.id))
           |> Map.get(:latest_attempt_id) == attempt.id

    assert Enum.find(session_snapshot.attempts, &(&1.id == attempt.id))

    assert %{
             status: status
           } = Enum.find(session_snapshot.attempts, &(&1.id == attempt.id))

    assert status in [
             :pending,
             :running,
             :succeeded,
             :retryable_failed,
             :terminal_failed
           ]

    assert Enum.find(session_snapshot.leases, &(&1.id == lease.id))

    assert Enum.find(session_snapshot.leases, &(&1.id == lease.id)).workspace_path ==
             lease.workspace_path

    assert {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    assert run_snapshot.run.id == run.id
    assert run_snapshot.run.latest_attempt_id == attempt.id
    assert Enum.any?(run_snapshot.attempts, &(&1.id == attempt.id))
    assert Enum.any?(run_snapshot.leases, &(&1.id == lease.id))
    assert Enum.any?(run_snapshot.events, &(&1.event.type == :run_submitted))

    assert :ok = SessionServer.close(session_id)
  end

  test "submit can persist lineage metadata and session snapshots enumerate multiple runs" do
    session_id = unique_id("session-multi-run")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-multi-run")

    assert {:ok, %{run: root_run}} =
             SessionServer.submit(
               session_id,
               "parent run for snapshot test",
               role: :coordinator
             )

    assert {:ok, %{run: child_run}} =
             SessionServer.submit(
               session_id,
               "child run for snapshot test",
               parent_run_id: root_run.id,
               role: :worker
             )

    assert {:ok, session_snapshot} = SessionServer.session_snapshot(session_id)
    run_ids = Enum.map(session_snapshot.runs, & &1.id)
    assert MapSet.new(run_ids) == MapSet.new([root_run.id, child_run.id])
    assert MapSet.new(session_snapshot.session.run_ids) == MapSet.new(run_ids)
    assert session_snapshot.session.active_run_id in [root_run.id, child_run.id]
    assert session_snapshot.session.status in [:initializing, :active]

    assert {:ok, root_snapshot} = SessionServer.run_snapshot(session_id, root_run.id)
    assert root_snapshot.run.id == root_run.id
    assert root_snapshot.run.parent_run_id == nil
    assert root_snapshot.run.role == :coordinator

    assert Enum.any?(
             root_snapshot.events,
             &(&1.event.type == :run_submitted && &1.event.payload[:run_id] == root_run.id)
           )

    assert {:ok, child_snapshot} = SessionServer.run_snapshot(session_id, child_run.id)
    assert child_snapshot.run.id == child_run.id
    assert child_snapshot.run.parent_run_id == root_run.id
    assert child_snapshot.run.role == :worker

    assert Enum.any?(
             child_snapshot.events,
             &(&1.event.type == :run_submitted && &1.event.payload[:run_id] == child_run.id)
           )

    refute Enum.any?(
             child_snapshot.events,
             &(&1.event.type == :run_submitted && &1.event.payload[:run_id] == root_run.id)
           )

    assert :ok = SessionServer.close(session_id)
  end

  test "approve finalizes run outcome and seals accepted artifact set" do
    session_id = unique_id("session-approve")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-approve")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "approve pending run",
               execution_adapter: Jidoka.TestAttemptExecutionAdapters.Success,
               verification_adapter: Jidoka.TestVerificationAdapters.Passed
             )

    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)
    {:ok, pre_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    _pre_attempt = latest_attempt(pre_snapshot)

    assert :ok = SessionServer.approve(session_id, run.id)

    {:ok, snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest = latest_attempt(snapshot)

    assert snapshot.run.status == :completed
    assert snapshot.run.outcome == :approved
    assert latest.status == :succeeded
    assert snapshot.run.artifact_ids == latest.artifact_ids

    assert Enum.any?(
             snapshot.outcomes,
             &(&1.outcome == :approved and &1.attempt_id == snapshot.run.latest_attempt_id)
           )

    assert {:error, {:invalid_run_status_for_action, :approve, :awaiting_approval, :completed}} =
             SessionServer.approve(session_id, run.id)
  end

  test "reject records terminal outcome without mutating latest attempt artifact ids" do
    session_id = unique_id("session-reject")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-reject")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "reject run",
               execution_adapter: Jidoka.TestAttemptExecutionAdapters.Success,
               verification_adapter: Jidoka.TestVerificationAdapters.Passed
             )

    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)
    {:ok, pre_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    pre_attempt = latest_attempt(pre_snapshot)
    pre_artifact_ids = pre_attempt.artifact_ids

    assert :ok = SessionServer.reject(session_id, run.id)
    {:ok, snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest = latest_attempt(snapshot)

    assert snapshot.run.status == :failed
    assert snapshot.run.outcome == :terminal_failed
    assert latest.status == :succeeded
    assert latest.artifact_ids == pre_artifact_ids

    assert Enum.any?(
             snapshot.outcomes,
             &(&1.outcome == :terminal_failed and
                 &1.attempt_id == snapshot.run.latest_attempt_id)
           )
  end

  test "retry creates new attempt and fresh isolated environment lease" do
    session_id = unique_id("session-retry")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-retry")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "retry run",
               execution_adapter: Jidoka.TestAttemptExecutionAdapters.Success,
               verification_adapter: Jidoka.TestVerificationAdapters.RetryableFailed
             )

    assert :ok = await_run_status(session_id, run.id, :failed)

    {:ok, pre_retry_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    pre_attempt = latest_attempt(pre_retry_snapshot)
    pre_lease = Enum.find(pre_retry_snapshot.leases, &(&1.attempt_id == pre_attempt.id))
    assert pre_lease
    assert pre_attempt.status == :succeeded

    assert :ok = SessionServer.retry(session_id, run.id)

    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)

    {:ok, retry_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    retry_attempt = latest_attempt(retry_snapshot)
    retry_lease = Enum.find(retry_snapshot.leases, &(&1.attempt_id == retry_attempt.id))

    assert retry_attempt.attempt_number == 2
    assert retry_attempt.id != pre_attempt.id
    assert retry_lease.attempt_id == retry_attempt.id
    assert retry_attempt.status == :succeeded
    assert retry_snapshot.run.status == :awaiting_approval
    assert retry_snapshot.run.outcome == nil
    assert retry_lease.id != pre_lease.id
    assert retry_lease.workspace_path != pre_lease.workspace_path
    assert retry_lease.workspace_path =~ run.id
    assert retry_lease.workspace_path =~ retry_attempt.id
  end

  test "cancel stops running attempt and persists canceled run and attempt outcomes" do
    session_id = unique_id("session-cancel")
    assert {:ok, ^session_id} = SessionServer.open(id: session_id, cwd: "/tmp/session-cancel")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "cancel in-flight",
               execution_adapter: CancelSlowAdapter
             )

    assert :ok = await_attempt_status(session_id, run.id, :running)
    assert :ok = SessionServer.cancel(session_id, run.id)
    assert :ok = await_run_status(session_id, run.id, :canceled)

    {:ok, snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest = latest_attempt(snapshot)

    assert snapshot.run.status == :canceled
    assert snapshot.run.outcome == :canceled
    assert latest.status == :canceled
    assert latest.metadata.cancellation_reason == :operator
    assert Enum.any?(snapshot.outcomes, &(&1.outcome == :canceled and &1.attempt_id == latest.id))
  end

  test "resume marks orphaned running attempt as terminal_failed and cleans workspace" do
    session_id = unique_id("session-orphaned-running")

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/session-orphaned-running")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "resume interrupted attempt",
               execution_adapter: HangingAdapter
             )

    assert :ok = await_attempt_status(session_id, run.id, :running)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    running_attempt = latest_attempt(run_snapshot)
    lease = Enum.find(run_snapshot.leases, &(&1.attempt_id == running_attempt.id))
    assert lease
    assert lease.status == :active

    :ok = File.mkdir_p!(lease.workspace_path)
    assert File.exists?(lease.workspace_path)

    assert :ok = Jidoka.AttemptWorker.stop(running_attempt.id)

    assert :ok = SessionServer.close(session_id)
    assert {:ok, ^session_id} = SessionServer.resume(session_id)
    assert :ok = await_run_status(session_id, run.id, :failed)
    assert :ok = await_attempt_status(session_id, run.id, :terminal_failed)

    assert :ok = SessionServer.close(session_id)

    {:ok, resumed_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    resumed_attempt = latest_attempt(resumed_snapshot)
    resumed_lease = Enum.find(resumed_snapshot.leases, &(&1.attempt_id == resumed_attempt.id))

    assert resumed_attempt.status == :terminal_failed
    assert resumed_snapshot.run.status == :failed
    assert resumed_snapshot.run.outcome == :terminal_failed
    assert resumed_lease.status == :expired
    assert resumed_lease.metadata.orphaned_recovery == :running_worker_missing
    assert resumed_lease.metadata.orphaned_cleanup_status == :removed
    refute File.exists?(lease.workspace_path)

    assert Enum.any?(
             resumed_snapshot.events,
             &(&1.event.type == :attempt_failed &&
                 &1.event.payload[:reason] == :orphaned_running_worker)
           )
  end

  test "resume reattaches orphaned pending attempt when workspace lease is present" do
    session_id = unique_id("session-orphaned-pending")

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/session-orphaned-pending")

    assert {:ok, run} =
             Run.new(
               id: unique_id("run-orphaned-pending"),
               session_id: session_id,
               task: "reattach orphaned attempt"
             )

    assert :ok = SessionServer.persist_run(run)

    attempt_id = unique_id("attempt-orphaned-pending")
    workspace_path = "/tmp/lease-orphaned-pending-#{attempt_id}"

    assert :ok = File.mkdir_p(workspace_path)

    assert {:ok, attempt} =
             Attempt.new(
               id: attempt_id,
               run_id: run.id,
               attempt_number: 1,
               status: :pending,
               metadata: %{
                 execution_adapter: CancelSlowAdapter,
                 verification_adapter: Jidoka.TestVerificationAdapters.Passed
               }
             )

    assert :ok = SessionServer.persist_attempt(attempt)

    assert {:ok, lease} =
             EnvironmentLease.new(
               id: unique_id("lease-orphaned-pending"),
               attempt_id: attempt.id,
               status: :active,
               mode: :exclusive,
               workspace_path: workspace_path,
               metadata: %{run_id: run.id, source_workspace_path: "/tmp/session-orphaned-pending"}
             )

    assert :ok = SessionServer.persist_environment_lease(lease)

    assert :ok = SessionServer.close(session_id)
    assert {:ok, ^session_id} = SessionServer.resume(session_id)
    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)
    assert :ok = await_attempt_status(session_id, run.id, :succeeded)

    {:ok, resumed_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    resumed_attempt = latest_attempt(resumed_snapshot)
    resumed_lease = Enum.find(resumed_snapshot.leases, &(&1.attempt_id == resumed_attempt.id))

    assert resumed_attempt.id == attempt.id
    assert resumed_attempt.status == :succeeded
    assert resumed_lease.status == :active
    assert File.exists?(workspace_path)

    assert Enum.any?(
             resumed_snapshot.events,
             &(&1.event.type == :run_updated &&
                 &1.event.payload[:operation] == :attempt_recovered &&
                 &1.event.payload[:strategy] == :reattach)
           )

    assert :ok = SessionServer.close(session_id)
  end

  test "artifact retention keeps latest diff/logs/transcript/verifier_report per attempt" do
    session_id = unique_id("session-artifact-retention")

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/session-artifact-retention")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "artifact retention",
               execution_adapter: CancelSlowAdapter,
               verification_adapter: Jidoka.TestVerificationAdapters.Passed
             )

    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    attempt = latest_attempt(run_snapshot)

    diff_old = unique_id("artifact-diff-old")
    diff_new = unique_id("artifact-diff-new")
    transcript_old = unique_id("artifact-transcript-old")
    transcript_new = unique_id("artifact-transcript-new")
    log_old = unique_id("artifact-log-old")
    log_new = unique_id("artifact-log-new")
    verifier_old = unique_id("artifact-verifier-old")
    verifier_new = unique_id("artifact-verifier-new")

    assert :ok =
             SessionServer.persist_attempt_artifacts(
               attempt.id,
               [
                 %{id: diff_old, type: :diff, location: "/tmp/#{diff_old}"},
                 %{id: diff_new, type: :diff, location: "/tmp/#{diff_new}"},
                 %{id: transcript_old, type: :transcript, location: "/tmp/#{transcript_old}"},
                 %{id: transcript_new, type: :transcript, location: "/tmp/#{transcript_new}"},
                 %{id: log_old, type: :command_log, location: "/tmp/#{log_old}"},
                 %{id: log_new, type: :command_log, location: "/tmp/#{log_new}"},
                 %{id: verifier_old, type: :verifier_report, location: "/tmp/#{verifier_old}"},
                 %{id: verifier_new, type: :verifier_report, location: "/tmp/#{verifier_new}"}
               ]
             )

    {:ok, resumed_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    resumed_attempt = latest_attempt(resumed_snapshot)

    assert MapSet.new(resumed_attempt.artifact_ids) ==
             MapSet.new([diff_new, transcript_new, log_new, verifier_new])

    attempt_artifacts =
      Enum.filter(resumed_snapshot.artifacts, &(&1.attempt_id == resumed_attempt.id))

    assert Enum.count(attempt_artifacts, &(&1.type == :diff)) == 2
    assert Enum.count(attempt_artifacts, &(&1.type == :transcript)) == 2
    assert Enum.count(attempt_artifacts, &(&1.type == :command_log)) == 2
    assert Enum.count(attempt_artifacts, &(&1.type == :verifier_report)) == 2

    assert Enum.any?(attempt_artifacts, &(&1.id == diff_new and &1.status == :ready))
    assert Enum.any?(attempt_artifacts, &(&1.id == diff_old and &1.status == :archived))
    assert Enum.any?(attempt_artifacts, &(&1.id == transcript_new and &1.status == :ready))
    assert Enum.any?(attempt_artifacts, &(&1.id == transcript_old and &1.status == :archived))
    assert Enum.any?(attempt_artifacts, &(&1.id == log_new and &1.status == :ready))
    assert Enum.any?(attempt_artifacts, &(&1.id == log_old and &1.status == :archived))
    assert Enum.any?(attempt_artifacts, &(&1.id == verifier_new and &1.status == :ready))
    assert Enum.any?(attempt_artifacts, &(&1.id == verifier_old and &1.status == :archived))

    assert {:error, {:invalid_artifact_type, _, :execution_report}} =
             SessionServer.persist_attempt_artifacts(
               attempt.id,
               [
                 %{id: unique_id("artifact-bad"), type: :execution_report, location: "/tmp/bad"}
               ]
             )

    assert :ok = SessionServer.close(session_id)
  end

  test "operator transitions reject illegal action attempts" do
    session_id = unique_id("session-transitions")

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/session-transitions")

    assert {:ok, %{run: run}} = SessionServer.submit(session_id, "legal check run")

    assert {:error, {:invalid_run_status_for_action, :approve, :awaiting_approval, _}} =
             SessionServer.approve(session_id, run.id)

    assert {:error, {:invalid_run_status_for_action, :reject, :awaiting_approval, _}} =
             SessionServer.reject(session_id, run.id)

    assert {:error, {:invalid_run_status_for_action, :retry, :failed, _}} =
             SessionServer.retry(session_id, run.id)
  end

  defp unique_id(prefix) do
    "#{prefix}-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp await_attempt_status(session_id, run_id, expected_status) do
    await_attempt_status(session_id, run_id, expected_status, 25)
  end

  defp await_attempt_status(_session_id, _run_id, _expected_status, 0), do: :error

  defp await_attempt_status(session_id, run_id, expected_status, remaining) do
    case latest_attempt_status(session_id, run_id) do
      {:ok, status} when status == expected_status ->
        :ok

      _ ->
        Process.sleep(10)
        await_attempt_status(session_id, run_id, expected_status, remaining - 1)
    end
  end

  defp await_run_status(session_id, run_id, expected_status) do
    await_run_status(session_id, run_id, expected_status, 25)
  end

  defp await_run_status(_session_id, _run_id, _expected_status, 0), do: :error

  defp await_run_status(session_id, run_id, expected_status, remaining) do
    case latest_run_status(session_id, run_id) do
      {:ok, status} when status == expected_status ->
        :ok

      _ ->
        Process.sleep(10)
        await_run_status(session_id, run_id, expected_status, remaining - 1)
    end
  end

  defp latest_attempt_status(session_id, run_id) do
    with {:ok, run_snapshot} <- SessionServer.run_snapshot(session_id, run_id),
         latest_attempt when is_map(latest_attempt) <-
           Enum.find(run_snapshot.attempts, &(&1.id == run_snapshot.run.latest_attempt_id)) do
      {:ok, latest_attempt.status}
    else
      _ -> :error
    end
  end

  defp latest_run_status(session_id, run_id) do
    with {:ok, run_snapshot} <- SessionServer.run_snapshot(session_id, run_id) do
      {:ok, run_snapshot.run.status}
    else
      _ -> :error
    end
  end

  defp latest_attempt(run_snapshot) do
    Enum.find(run_snapshot.attempts, &(&1.id == run_snapshot.run.latest_attempt_id))
  end
end
