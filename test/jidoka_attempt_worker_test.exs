defmodule JidokaAttemptWorkerTest do
  use ExUnit.Case, async: false

  alias Jidoka.Bus
  alias Jidoka.SessionServer
  alias Jidoka.TestAttemptExecutionAdapters.{Failure, MutationProgress, Success, ToolProgress}
  alias Jidoka.TestVerificationAdapters.{RetryableFailed, TerminalFailed}

  test "attempt worker streams progress, completion, and verifier pass updates run state" do
    session_id = unique_id("attempt-worker-success")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-success")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "implement login form",
               execution_adapter: Success
             )

    assert :ok = await_attempt_status(session_id, run.id, :succeeded)
    assert :ok = await_run_status(session_id, run.id, :awaiting_approval)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    assert run_snapshot.run.id == run.id
    assert run_snapshot.run.status == :awaiting_approval
    refute run_snapshot.run.outcome

    assert run_snapshot.run.latest_attempt_id == List.last(run_snapshot.attempts).id

    latest_attempt =
      Enum.find(run_snapshot.attempts, &(&1.id == run_snapshot.run.latest_attempt_id))

    assert latest_attempt.status == :succeeded
    assert latest_attempt.started_at
    assert latest_attempt.finished_at

    {:ok, log} = Bus.get_log(path: event_path(session_id))

    attempts_events =
      Enum.filter(log, fn entry ->
        entry.signal.payload[:attempt_id] == latest_attempt.id &&
          entry.signal.type in [:attempt_started, :attempt_progress, :attempt_completed]
      end)

    event_types = Enum.map(attempts_events, & &1.signal.type)

    assert event_types == [
             :attempt_started,
             :attempt_progress,
             :attempt_progress,
             :attempt_completed
           ]

    assert hd(attempts_events).signal.payload[:status] == :running

    latest_attempt = latest_attempt(run_snapshot)
    assert latest_attempt.verification_result_id

    verification =
      Enum.find(
        run_snapshot.verification_results,
        &(&1.id == latest_attempt.verification_result_id)
      )

    assert verification
    assert verification.status == :passed
    assert verification.outcome_summary == %{checks: :noop}
  end

  test "attempt worker records tool progress emitted by Jidoka tools" do
    session_id = unique_id("attempt-worker-tool-progress")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-tool-progress")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "read a fixture file",
               execution_adapter: ToolProgress
             )

    assert :ok = await_attempt_status(session_id, run.id, :succeeded)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest_attempt = latest_attempt(run_snapshot)

    {:ok, log} = Bus.get_log(path: event_path(session_id))

    tool_events =
      Enum.filter(log, fn entry ->
        entry.signal.type == :attempt_progress &&
          entry.signal.payload[:attempt_id] == latest_attempt.id &&
          entry.signal.payload[:metadata][:tool] == "read_file"
      end)

    assert Enum.map(tool_events, & &1.signal.payload[:label]) == [
             :tool_requested,
             :tool_permission_granted,
             :tool_started,
             :tool_completed
           ]
  end

  test "attempt worker records mutation and verification tool progress durably" do
    session_id = unique_id("attempt-worker-mutation-progress")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-mutation-progress")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "write a fixture file and run checks",
               execution_adapter: MutationProgress
             )

    assert :ok = await_attempt_status(session_id, run.id, :succeeded, 500)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest_attempt = latest_attempt(run_snapshot)

    {:ok, log} = Bus.get_log(path: event_path(session_id))

    progress =
      Enum.filter(log, fn entry ->
        entry.signal.type == :attempt_progress &&
          entry.signal.payload[:attempt_id] == latest_attempt.id
      end)

    assert Enum.any?(progress, &(&1.signal.payload[:metadata][:tool] == "write_file"))
    assert Enum.any?(progress, &(&1.signal.payload[:metadata][:tool] == "mix_check"))
    assert Enum.any?(progress, &(&1.signal.payload[:label] == :verification_step_completed))

    assert Enum.any?(
             run_snapshot.artifacts,
             &(&1.type == :verifier_report and &1.status == :ready)
           )
  end

  test "attempt worker emits failure event when adapter returns error" do
    session_id = unique_id("attempt-worker-failure")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-failure")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "implement flaky behavior",
               execution_adapter: Failure
             )

    assert :ok = await_attempt_status(session_id, run.id, :terminal_failed)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)

    latest_attempt =
      Enum.find(run_snapshot.attempts, &(&1.id == run_snapshot.run.latest_attempt_id))

    assert latest_attempt.status == :terminal_failed

    {:ok, log} = Bus.get_log(path: event_path(session_id))

    attempts_events =
      Enum.filter(log, fn entry ->
        entry.signal.payload[:attempt_id] == latest_attempt.id &&
          entry.signal.type in [:attempt_started, :attempt_failed]
      end)

    event_types = Enum.map(attempts_events, & &1.signal.type)

    assert event_types == [:attempt_started, :attempt_failed]

    assert Enum.any?(
             attempts_events,
             &(&1.signal.payload[:reason] == {:error, %{reason: :stubbed_execution_failure}})
           )
  end

  test "verification retryable failure puts run into failed run state" do
    session_id = unique_id("attempt-worker-retryable")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-retryable")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "fix flaky tests",
               execution_adapter: Success,
               verification_adapter: RetryableFailed
             )

    assert :ok = await_run_status(session_id, run.id, :failed)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest_attempt = latest_attempt(run_snapshot)

    assert latest_attempt.status == :succeeded
    assert latest_attempt.verification_result_id
    assert run_snapshot.run.status == :failed
    assert run_snapshot.run.outcome == :retryable_failed

    verification =
      Enum.find(
        run_snapshot.verification_results,
        &(&1.id == latest_attempt.verification_result_id)
      )

    assert verification.status == :retryable_failed
  end

  test "verification terminal failure puts run into failed run state" do
    session_id = unique_id("attempt-worker-terminal")
    on_exit(fn -> SessionServer.close(session_id) end)

    assert {:ok, ^session_id} =
             SessionServer.open(id: session_id, cwd: "/tmp/attempt-worker-terminal")

    assert {:ok, %{run: run}} =
             SessionServer.submit(
               session_id,
               "fix flaky tests",
               execution_adapter: Success,
               verification_adapter: TerminalFailed
             )

    assert :ok = await_run_status(session_id, run.id, :failed)

    {:ok, run_snapshot} = SessionServer.run_snapshot(session_id, run.id)
    latest_attempt = latest_attempt(run_snapshot)

    assert latest_attempt.status == :succeeded
    assert run_snapshot.run.outcome == :terminal_failed
    assert latest_attempt.verification_result_id

    verification =
      Enum.find(
        run_snapshot.verification_results,
        &(&1.id == latest_attempt.verification_result_id)
      )

    assert verification.status == :terminal_failed
  end

  defp await_attempt_status(session_id, run_id, expected_status) do
    await_attempt_status(session_id, run_id, expected_status, 25)
  end

  defp await_attempt_status(session_id, run_id, expected_status, remaining) when remaining > 0 do
    case latest_attempt_status(session_id, run_id) do
      {:ok, status} when status == expected_status ->
        :ok

      _ ->
        Process.sleep(10)
        await_attempt_status(session_id, run_id, expected_status, remaining - 1)
    end
  end

  defp await_attempt_status(_session_id, _run_id, _expected_status, 0),
    do: :error

  defp await_run_status(session_id, run_id, expected_status) do
    await_run_status(session_id, run_id, expected_status, 25)
  end

  defp await_run_status(session_id, run_id, expected_status, remaining) when remaining > 0 do
    case latest_run_status(session_id, run_id) do
      {:ok, status} when status == expected_status ->
        :ok

      _ ->
        Process.sleep(10)
        await_run_status(session_id, run_id, expected_status, remaining - 1)
    end
  end

  defp await_run_status(_session_id, _run_id, _expected_status, 0), do: :error

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

  defp unique_id(prefix) do
    prefix <> "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp event_path(session_id) do
    "jidoka.session." <> Base.url_encode64(session_id, padding: false) <> ".events"
  end
end
