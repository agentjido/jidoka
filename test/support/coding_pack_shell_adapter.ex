defmodule Jidoka.TestSupport.CodingPackShellAdapter do
  @moduledoc false

  @behaviour Jidoka.ExecutionEnvironment.Adapter

  alias Jidoka.Cancellation.Token
  alias Jidoka.ExecutionEnvironment.{Binding, Checkpoint, EnforcementEvidence}

  @impl true
  def open(profile, _request, opts) do
    record(opts, :open)

    binding =
      Binding.new!(
        adapter_id: profile.adapter_id,
        adapter_version: "1",
        profile_id: profile.profile_id,
        profile_digest: profile.digest,
        resource_ref: "shell-environment",
        revision: 0,
        state: :available
      )

    {:ok, binding, evidence(opts)}
  end

  @impl true
  def acquire(binding, opts) do
    record(opts, :acquire)
    {:ok, %{resource_ref: binding.resource_ref}, evidence(opts)}
  end

  @impl true
  def execute(_handle, request, opts) do
    record(opts, {:execute, request})

    case mode(opts) do
      :adapter_error ->
        {:error, :injected_execute_failure}

      :cancelled ->
        if token = Keyword.get(opts, :cancellation), do: Token.request(token)
        {:ok, result(:cancelled, request, opts), execute_evidence(request, opts)}

      mode ->
        {:ok, result(mode, request, opts), execute_evidence(request, opts)}
    end
  end

  @impl true
  def checkpoint(_handle, binding, opts) do
    {:ok, binding,
     Checkpoint.new!(
       checkpoint_ref: "shell-checkpoint",
       binding_revision: binding.revision,
       profile_digest: binding.profile_digest,
       evidence_digest: "sha256:" <> String.duplicate("c", 64),
       preserves: %{"files" => true},
       forkable: false,
       created_at_ms: 1
     ), evidence(opts)}
  end

  @impl true
  def restore(binding, _checkpoint, opts), do: {:ok, binding, evidence(opts)}

  @impl true
  def fork(_binding, _checkpoint, _opts), do: {:error, :unsupported}

  @impl true
  def close(_handle, opts) do
    record(opts, :close)
    if mode(opts) == :close_error, do: {:error, :injected_close_failure}, else: {:ok, evidence(opts)}
  end

  @impl true
  def cleanup(_binding, opts), do: {:ok, evidence(opts)}

  defp result(:nonzero, _request, _opts),
    do: %{"status" => "nonzero", "stdout" => "", "stderr" => "failed", "exit_status" => 7, "duration_ms" => 4}

  defp result(:timeout, _request, _opts),
    do: %{"status" => "timeout", "stdout" => "partial", "stderr" => "", "exit_status" => nil, "duration_ms" => 10}

  defp result(:cancelled, _request, _opts),
    do: %{"status" => "cancelled", "stdout" => "", "stderr" => "", "exit_status" => nil, "duration_ms" => 2}

  defp result(:oversized, _request, _opts),
    do: %{
      "status" => "ok",
      "stdout" => String.duplicate("o", 80),
      "stderr" => String.duplicate("e", 80),
      "exit_status" => 0,
      "duration_ms" => 3
    }

  defp result(_mode, request, opts) do
    state = state(opts)
    stderr = if state, do: Agent.get(state, &Map.get(&1, :stderr, "diagnostic")), else: "diagnostic"

    %{
      "status" => "ok",
      "stdout" => request["stdin"] <> Enum.join(request["args"], " "),
      "stderr" => stderr,
      "exit_status" => 0,
      "duration_ms" => 3
    }
  end

  defp execute_evidence(request, opts) do
    facts = %{
      "shell_execute" => true,
      "cwd_confined" => true,
      "wall_timeout" => true,
      "output_limit" => true,
      "cancellation" => true,
      "command_class" => request["command_class"]
    }

    overrides = if state(opts), do: Agent.get(state(opts), &Map.get(&1, :evidence, %{})), else: %{}

    evidence(opts, %{
      facts: facts,
      applied_limits: %{
        "wall_time_ms" => request["timeout_ms"],
        "output_bytes" => request["max_output_bytes"]
      }
    })
    |> then(fn evidence -> struct!(evidence, overrides) end)
  end

  defp evidence(_opts, overrides \\ %{}) do
    EnforcementEvidence.new!(
      Map.merge(
        %{
          status: :confirmed,
          adapter_id: "test.shell",
          backend: "fake-shell",
          isolation: :container,
          network: :restricted,
          workspace: :isolated_copy,
          applied_limits: %{"wall_time_ms" => 1_000, "output_bytes" => 32},
          observed_at_ms: 1,
          facts: %{}
        },
        overrides
      )
    )
  end

  defp record(opts, event) do
    if state = state(opts),
      do: Agent.update(state, &Map.update(&1, :events, [event], fn events -> [event | events] end))
  end

  defp mode(opts) do
    if state = state(opts), do: Agent.get(state, &Map.get(&1, :mode, :success)), else: :success
  end

  defp state(opts), do: Keyword.get(opts, :state)
end
