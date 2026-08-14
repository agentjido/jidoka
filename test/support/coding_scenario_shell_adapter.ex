defmodule Jidoka.TestSupport.CodingScenarioShellAdapter do
  @moduledoc false

  @behaviour Jidoka.ExecutionEnvironment.Adapter

  alias Jidoka.ExecutionEnvironment.{Binding, Checkpoint, EnforcementEvidence}

  @default_limits %{"wall_time_ms" => 60_000, "output_bytes" => 262_144}

  @impl true
  def open(profile, _request, opts) do
    root = Keyword.fetch!(opts, :root)
    record(opts, {:open, root})

    binding =
      Binding.new!(
        adapter_id: profile.adapter_id,
        adapter_version: "1",
        profile_id: profile.profile_id,
        profile_digest: profile.digest,
        resource_ref: "coding-scenario-shell",
        revision: 0,
        state: :available
      )

    {:ok, binding, evidence()}
  end

  @impl true
  def acquire(_binding, opts) do
    root = Keyword.fetch!(opts, :root)
    record(opts, {:acquire, root})
    {:ok, %{root: root}, evidence()}
  end

  @impl true
  def execute(%{root: root}, request, opts) do
    record(opts, {:execute, request})

    with false <- request["network"],
         true <- request["command"] in ["git", "mix"],
         {:ok, cwd} <- confined_cwd(root, request["cwd"]),
         {:ok, result} <- run(request["command"], request["args"], cwd, request["timeout_ms"]) do
      {:ok, result, execute_evidence(request)}
    else
      true -> {:error, :network_not_disabled}
      false -> {:error, :command_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def checkpoint(_handle, binding, _opts) do
    checkpoint =
      Checkpoint.new!(
        checkpoint_ref: "coding-scenario-checkpoint",
        binding_revision: binding.revision,
        profile_digest: binding.profile_digest,
        evidence_digest: "sha256:" <> String.duplicate("c", 64),
        preserves: %{"files" => true},
        forkable: false,
        created_at_ms: 1
      )

    {:ok, binding, checkpoint, evidence()}
  end

  @impl true
  def restore(binding, _checkpoint, _opts), do: {:ok, binding, evidence()}

  @impl true
  def fork(_binding, _checkpoint, _opts), do: {:error, :unsupported}

  @impl true
  def close(_handle, opts) do
    record(opts, :close)
    {:ok, evidence()}
  end

  @impl true
  def cleanup(_binding, _opts), do: {:ok, evidence()}

  defp run(command, args, cwd, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        System.cmd(command, args,
          cd: cwd,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, result("ok", output, 0, started_at)}

      {:ok, {output, status}} ->
        {:ok, result("nonzero", output, status, started_at)}

      {:exit, reason} ->
        {:error, {:command_crashed, reason}}

      nil ->
        {:ok, result("timeout", "", nil, started_at)}
    end
  end

  defp result(status, output, exit_status, started_at) do
    %{
      "status" => status,
      "stdout" => output,
      "stderr" => "",
      "exit_status" => exit_status,
      "duration_ms" => max(System.monotonic_time(:millisecond) - started_at, 0)
    }
  end

  defp confined_cwd(root, cwd) when is_binary(cwd) do
    expanded_root = Path.expand(root)
    expanded = Path.expand(cwd, expanded_root)

    if expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/"),
      do: {:ok, expanded},
      else: {:error, :cwd_outside_workspace}
  end

  defp confined_cwd(_root, _cwd), do: {:error, :invalid_cwd}

  defp execute_evidence(request) do
    evidence(
      %{
        "wall_time_ms" => request["timeout_ms"],
        "output_bytes" => request["max_output_bytes"]
      },
      %{
        "shell_execute" => true,
        "cwd_confined" => true,
        "wall_timeout" => true,
        "output_limit" => true,
        "cancellation" => true,
        "command_class" => request["command_class"]
      }
    )
  end

  defp evidence(limits \\ @default_limits, facts \\ %{}) do
    EnforcementEvidence.new!(
      status: :confirmed,
      adapter_id: "test.coding-scenario-shell",
      backend: "local-test-process",
      isolation: :process,
      network: :disabled,
      workspace: :isolated_copy,
      applied_limits: limits,
      observed_at_ms: 1,
      facts: facts
    )
  end

  defp record(opts, event) do
    if state = Keyword.get(opts, :state) do
      Agent.update(state, &Map.update(&1, :events, [event], fn events -> [event | events] end))
    end
  end
end
