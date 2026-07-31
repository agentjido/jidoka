defmodule JidokaExamples.Executor do
  @moduledoc false

  alias JidokaExamples.GateResult

  @output_limit 65_536
  @max_workers 4

  @spec run([map()], keyword()) :: %{artifacts: map(), gates: [GateResult.t()]}
  def run(gates, opts \\ []) do
    stages = gates |> Enum.group_by(& &1.stage) |> Enum.sort_by(&elem(&1, 0))
    run_stages(stages, %{artifacts: %{}, gates: []}, opts)
  end

  defp run_stages([], acc, _opts), do: acc

  defp run_stages([{_stage, stage_gates} | remaining], acc, opts) do
    results = run_stage(stage_gates, opts)
    next = merge_results(acc, results)

    if Enum.any?(results, fn {gate, _artifact} -> gate.status == :error end) do
      skipped =
        remaining
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.map(&skipped_result(&1, "An earlier gate failed."))

      merge_results(next, skipped)
    else
      run_stages(remaining, next, opts)
    end
  end

  defp run_stage(gates, opts) do
    gates
    |> Task.async_stream(&run_gate(&1, opts),
      max_concurrency: @max_workers,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.zip(gates)
    |> Enum.map(fn
      {{:ok, result}, _gate} -> result
      {{:exit, reason}, gate} -> worker_error_result(gate, reason)
    end)
  end

  defp run_gate(gate, opts) do
    {artifact_path, artifact_env} = artifact_env(gate)
    env = Map.get(gate, :env, []) ++ artifact_env
    started_at = System.monotonic_time()

    command_result =
      run_command(gate.command, gate.cd,
        env: env,
        id: gate.id,
        timeout_ms: gate.timeout_ms,
        verbose: Keyword.get(opts, :verbose, false)
      )

    duration_ms = elapsed_ms(started_at)
    artifact = read_artifact(artifact_path)
    cleanup_artifact(artifact_path)

    result =
      case command_result do
        {:ok, output} ->
          %GateResult{
            command: gate.command,
            duration_ms: duration_ms,
            id: gate.id,
            message: nil,
            output: if(Keyword.get(opts, :verbose, false), do: output, else: nil),
            scope: gate.scope,
            status: :ok,
            subject: gate.subject
          }

        {:error, reason, output} ->
          %GateResult{
            command: gate.command,
            duration_ms: duration_ms,
            id: gate.id,
            message: reason,
            output: output,
            scope: gate.scope,
            status: :error,
            subject: gate.subject
          }
      end

    {result, artifact_entry(gate, artifact)}
  rescue
    exception ->
      result = %GateResult{
        command: gate.command,
        duration_ms: 0,
        id: gate.id,
        message: Exception.message(exception),
        output: nil,
        scope: gate.scope,
        status: :error,
        subject: gate.subject
      }

      {result, nil}
  end

  defp run_command([executable_name | args], cd, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    id = Keyword.fetch!(opts, :id)
    verbose? = Keyword.fetch!(opts, :verbose)
    env = Keyword.get(opts, :env, [])

    case System.find_executable(executable_name) do
      nil ->
        {:error, "Executable is not available: #{executable_name}", ""}

      executable ->
        port =
          Port.open(
            {:spawn_executable, executable},
            [
              :binary,
              :exit_status,
              :hide,
              :stderr_to_stdout,
              :use_stdio,
              {:args, args},
              {:cd, cd},
              {:env, encode_env(env)}
            ]
          )

        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect(port, id, deadline, timeout_ms, verbose?, "", "")
    end
  end

  defp collect(port, id, deadline, timeout_ms, verbose?, tail, pending) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        next_pending = stream(data, id, verbose?, pending)

        collect(
          port,
          id,
          deadline,
          timeout_ms,
          verbose?,
          append_tail(tail, data),
          next_pending
        )

      {^port, {:exit_status, 0}} ->
        flush_pending(id, verbose?, pending)
        {:ok, tail}

      {^port, {:exit_status, status}} ->
        flush_pending(id, verbose?, pending)
        {:error, "Exited with status #{status}.", tail}
    after
      remaining ->
        Port.close(port)
        flush_pending(id, verbose?, pending)
        {:error, "Timed out after #{timeout_ms} milliseconds.", tail}
    end
  end

  defp stream(_data, _id, false, _pending), do: ""

  defp stream(data, id, true, pending) do
    [next_pending | complete] =
      (pending <> data)
      |> String.split("\n")
      |> Enum.reverse()

    complete
    |> Enum.reverse()
    |> Enum.each(&IO.puts("[#{id}] #{&1}"))

    next_pending
  end

  defp flush_pending(_id, _verbose?, ""), do: :ok
  defp flush_pending(id, true, pending), do: IO.puts("[#{id}] #{pending}")
  defp flush_pending(_id, false, _pending), do: :ok

  defp append_tail(tail, data) do
    combined = tail <> data

    if byte_size(combined) > @output_limit do
      binary_part(combined, byte_size(combined) - @output_limit, @output_limit)
    else
      combined
    end
  end

  defp artifact_env(%{artifact: :exunit}) do
    path =
      Path.join(
        System.tmp_dir!(),
        "jidoka-proof-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    {path, [{"JIDOKA_PROOF_RESULT_PATH", path}]}
  end

  defp artifact_env(_gate), do: {nil, []}

  defp read_artifact(nil), do: nil

  defp read_artifact(path) do
    with {:ok, content} <- File.read(path),
         {:ok, artifact} <- Jason.decode(content) do
      {:ok, artifact}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_artifact(nil), do: :ok
  defp cleanup_artifact(path), do: File.rm(path)

  defp artifact_entry(%{artifact: :exunit, subject: subject}, artifact), do: {subject, artifact}
  defp artifact_entry(_gate, _artifact), do: nil

  defp merge_results(acc, results) do
    artifacts =
      Enum.reduce(results, acc.artifacts, fn
        {_gate, {subject, artifact}}, current -> Map.put(current, subject, artifact)
        {_gate, nil}, current -> current
      end)

    %{artifacts: artifacts, gates: acc.gates ++ Enum.map(results, &elem(&1, 0))}
  end

  defp skipped_result(gate, message) do
    {%GateResult{
       command: gate.command,
       duration_ms: 0,
       id: gate.id,
       message: message,
       output: nil,
       scope: gate.scope,
       status: :skipped,
       subject: gate.subject
     }, nil}
  end

  defp worker_error_result(gate, reason) do
    {%GateResult{
       command: gate.command,
       duration_ms: 0,
       id: gate.id,
       message: "Worker exited: #{inspect(reason)}",
       output: nil,
       scope: gate.scope,
       status: :error,
       subject: gate.subject
     }, nil}
  end

  defp encode_env(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end
end
