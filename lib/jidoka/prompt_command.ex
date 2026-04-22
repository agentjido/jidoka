defmodule Jidoka.PromptCommand do
  @moduledoc false

  alias Jidoka.Agent
  alias Jidoka.AttemptExecution.JidoAIAgentAdapter
  alias Jidoka.RuntimeBootstrap
  alias Jidoka.TuiServer

  @poll_interval_ms 100

  @spec run(String.t(), keyword()) :: 0 | 1
  def run(prompt, opts \\ []) when is_binary(prompt) do
    prompt = String.trim(prompt)

    if prompt == "" do
      IO.puts(:stderr, "prompt text required")
      1
    else
      do_run(prompt, opts)
    end
  end

  defp do_run(prompt, opts) do
    with :ok <- ensure_started(),
         {:ok, session_id} <- Agent.open(cwd: workspace_root(), metadata: session_metadata()),
         {:ok, tui_pid} <-
           TuiServer.start_link(session: session_id, poll_interval: @poll_interval_ms),
         {:ok, %{run: run, attempt: attempt}} <-
           Agent.submit(
             session_id,
             prompt,
             execution_adapter: execution_adapter(opts),
             attempt_metadata: prompt_attempt_metadata(opts),
             verification_adapter: Jidoka.Verifier.NoopAdapter
           ) do
      IO.puts("session=#{session_id} run=#{run.id} attempt=#{attempt.id}")

      try do
        case await_run_completion(session_id, run.id, tui_pid, MapSet.new(), false) do
          {:ok, snapshot} ->
            print_response(snapshot)
            0

          {:error, snapshot} ->
            print_failure(snapshot)
            1
        end
      after
        TuiServer.stop(tui_pid)
        Agent.close(session_id)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, format_reason(reason))
        1
    end
  end

  defp ensure_started do
    RuntimeBootstrap.ensure_started()
  end

  defp await_run_completion(session_id, run_id, tui_pid, seen_lines, approved?) do
    seen_lines = flush_runtime_lines(tui_pid, seen_lines)

    case Agent.run_snapshot(session_id, run_id) do
      {:ok, snapshot} ->
        case snapshot.run.status do
          :queued ->
            sleep_then_continue(session_id, run_id, tui_pid, seen_lines, approved?)

          :running ->
            sleep_then_continue(session_id, run_id, tui_pid, seen_lines, approved?)

          :awaiting_approval ->
            if approved? do
              sleep_then_continue(session_id, run_id, tui_pid, seen_lines, approved?)
            else
              IO.puts("approval=auto")

              case Agent.approve(session_id, run_id) do
                :ok ->
                  sleep_then_continue(session_id, run_id, tui_pid, seen_lines, true)

                {:error, reason} ->
                  IO.puts(:stderr, format_reason(reason))
                  {:error, snapshot}
              end
            end

          :completed ->
            flush_runtime_lines(tui_pid, seen_lines)
            {:ok, snapshot}

          :failed ->
            flush_runtime_lines(tui_pid, seen_lines)
            {:error, snapshot}

          :canceled ->
            flush_runtime_lines(tui_pid, seen_lines)
            {:error, snapshot}
        end

      {:error, reason} ->
        IO.puts(:stderr, format_reason(reason))

        {:error,
         %{
           run: %{status: :failed, outcome: :terminal_failed},
           attempts: [],
           artifacts: []
         }}
    end
  end

  defp sleep_then_continue(session_id, run_id, tui_pid, seen_lines, approved?) do
    Process.sleep(@poll_interval_ms)
    await_run_completion(session_id, run_id, tui_pid, seen_lines, approved?)
  end

  defp flush_runtime_lines(tui_pid, seen_lines) do
    state = TuiServer.state(tui_pid)

    (state.activity_lines ++ state.focused_progress_lines)
    |> Enum.reduce(seen_lines, fn line, acc ->
      if MapSet.member?(acc, line) do
        acc
      else
        IO.puts(line)
        MapSet.put(acc, line)
      end
    end)
  end

  defp print_response(snapshot) do
    response_text = extract_response_text(snapshot)

    IO.puts("status=completed")

    if is_binary(response_text) and response_text != "" do
      IO.puts("")
      IO.puts(response_text)
    end
  end

  defp print_failure(snapshot) do
    attempt = latest_attempt(snapshot)

    error =
      attempt &&
        (Map.get(attempt.metadata || %{}, :execution_failure_reason) ||
           Map.get(attempt.metadata || %{}, "execution_failure_reason"))

    IO.puts(:stderr, "status=#{snapshot.run.status}")

    if not is_nil(error) do
      IO.puts(:stderr, format_reason(error))
    end
  end

  defp extract_response_text(snapshot) do
    attempt = latest_attempt(snapshot)

    from_metadata =
      attempt &&
        (Map.get(attempt.metadata || %{}, :response_text) ||
           Map.get(attempt.metadata || %{}, "response_text"))

    from_artifact =
      snapshot.artifacts
      |> Enum.filter(&(&1.type == :prompt_report and &1.status == :ready))
      |> Enum.sort_by(
        fn artifact -> artifact.updated_at || artifact.created_at end,
        {:desc, DateTime}
      )
      |> Enum.find_value(fn artifact ->
        case artifact.location do
          path when is_binary(path) ->
            case File.read(path) do
              {:ok, contents} -> response_section(contents)
              {:error, _reason} -> nil
            end

          _ ->
            nil
        end
      end)

    from_metadata || from_artifact
  end

  defp response_section(contents) do
    case String.split(contents, "# Response\n\n", parts: 2) do
      [_prompt, response] -> String.trim(response)
      _ -> String.trim(contents)
    end
  end

  defp latest_attempt(snapshot) do
    snapshot.attempts
    |> Enum.sort_by(& &1.attempt_number, :desc)
    |> List.first()
  end

  defp execution_adapter(opts) do
    Keyword.get(opts, :execution_adapter) ||
      Application.get_env(:jidoka, :prompt_execution_adapter, JidoAIAgentAdapter)
  end

  defp prompt_attempt_metadata(opts) do
    %{
      model: Keyword.get(opts, :model),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      workspace_path: File.cwd!(),
      permission_mode:
        Keyword.get(opts, :permission_mode) || System.get_env("JIDOKA_PERMISSION_MODE") ||
          :read_only
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp workspace_root do
    path = Path.join(System.tmp_dir!(), "jidoka-cli")
    File.mkdir_p!(path)
    path
  end

  defp session_metadata do
    %{requested_cwd: File.cwd!()}
  end
end
