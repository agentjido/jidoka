defmodule Jidoka.ExecutionEnvironment.SessionSequenceTest do
  use ExUnit.Case, async: true

  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.Checkpoint
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.ProfileResolver
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Policy.Decision
  alias Jidoka.Session.Sequence

  @digest "sha256:" <> String.duplicate("a", 64)
  @image_digest "sha256:" <> String.duplicate("b", 64)

  defmodule Adapter do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    alias Jidoka.ExecutionEnvironment
    alias Jidoka.ExecutionEnvironment.Binding
    alias Jidoka.ExecutionEnvironment.Checkpoint
    alias Jidoka.ExecutionEnvironment.EnforcementEvidence

    @impl true
    def open(profile, _request, opts) do
      record(opts, :open)

      if Keyword.get(opts, :fail_open, false) do
        {:error, :open_failed}
      else
        binding =
          Binding.new!(
            adapter_id: profile.adapter_id,
            adapter_version: "1",
            profile_id: profile.profile_id,
            profile_digest: profile.digest,
            resource_ref: Keyword.get(opts, :resource_ref, "environment-cell"),
            state: :available
          )

        {:ok, binding, evidence(opts)}
      end
    end

    @impl true
    def acquire(binding, opts) do
      record(opts, :acquire)

      evidence =
        if Keyword.get(opts, :weak_evidence, false), do: %{evidence(opts) | status: :partial}, else: evidence(opts)

      {:ok, %{resource_ref: binding.resource_ref}, evidence}
    end

    @impl true
    def checkpoint(_handle, %Binding{} = binding, opts) do
      record(opts, :checkpoint)
      binding = %Binding{binding | revision: binding.revision + 1}

      checkpoint =
        Checkpoint.new!(
          checkpoint_ref: "checkpoint-#{binding.resource_ref}-#{binding.revision}",
          binding_revision: binding.revision,
          profile_digest: binding.profile_digest,
          evidence_digest: ExecutionEnvironment.digest(evidence(opts)),
          preserves: %{"files" => true},
          forkable: false,
          created_at_ms: binding.revision
        )

      {:ok, binding, checkpoint, evidence(opts)}
    end

    @impl true
    def restore(binding, _checkpoint, opts), do: {:ok, binding, evidence(opts)}

    @impl true
    def fork(_binding, _checkpoint, _opts), do: {:error, :unsupported}

    @impl true
    def close(_handle, opts) do
      record(opts, :close)
      {:ok, evidence(opts)}
    end

    @impl true
    def cleanup(_binding, opts) do
      record(opts, :cleanup)
      {:ok, evidence(opts)}
    end

    defp evidence(_opts) do
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "test.sequence-adapter",
        backend: "test-backend",
        isolation: :container,
        network: :disabled,
        workspace: :ephemeral,
        image_digest: "sha256:" <> String.duplicate("b", 64),
        applied_limits: %{},
        checkpoint: %{"supported" => true, "forkable" => false},
        observed_at_ms: 10
      )
    end

    defp record(opts, event), do: Agent.update(Keyword.fetch!(opts, :probe), &[event | &1])
  end

  test "one resolved environment spans two ordered turns and cleans after completion" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, session} = Jidoka.Session.start(spec(), "profiled-sequence")
    {:ok, llm_calls} = Agent.start_link(fn -> 0 end)
    parent = self()

    llm = fn _intent, _journal, context ->
      Agent.update(llm_calls, &(&1 + 1))
      send(parent, {:environment_runtime, Jidoka.Context.runtime(context)})
      {:ok, %{type: :final, content: "done"}}
    end

    assert {:ok,
            %Sequence.Result{
              status: :completed,
              session: %{environment: %{status: :cleaned}},
              steps: [_, _]
            }} =
             Jidoka.Session.run_sequence(session, ["one", "two"],
               execution_environment: resolved_environment(),
               execution_environment_policy: allow_policy(),
               execution_environment_adapter_opts: [probe: probe],
               llm: llm
             )

    assert Agent.get(llm_calls, & &1) == 2

    assert_receive {:environment_runtime,
                    %{execution_environment: %{handle: %Jidoka.ExecutionEnvironment.Manager.Handle{}}}}

    assert events(probe) == [
             :open,
             :acquire,
             :checkpoint,
             :close,
             :acquire,
             :checkpoint,
             :close,
             :cleanup
           ]
  end

  test "weak evidence prevents the first model effect" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, session} = Jidoka.Session.start(spec(), "weak-evidence")
    parent = self()

    assert {:ok, %Sequence.Result{status: :error, steps: []}} =
             Jidoka.Session.run_sequence(session, ["blocked"],
               execution_environment: resolved_environment(),
               execution_environment_policy: allow_policy(),
               execution_environment_adapter_opts: [probe: probe, weak_evidence: true],
               llm: fn _intent, _journal, _context ->
                 send(parent, :llm_called)
                 {:ok, %{type: :final, content: "unsafe"}}
               end
             )

    refute_received :llm_called
    assert events(probe) == [:open, :acquire, :close]
  end

  test "a turn error returns the final portable environment evidence" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, session} = Jidoka.Session.start(spec(), "error-evidence")

    assert {:ok,
            %Sequence.Result{
              status: :error,
              session: %{environment: %{status: :cleaned, evidence: %{status: :confirmed}}}
            }} =
             Jidoka.Session.run_sequence(session, ["fail"],
               execution_environment: resolved_environment(),
               execution_environment_policy: allow_policy(),
               execution_environment_adapter_opts: [probe: probe],
               llm: fn _intent, _journal, _context -> {:error, :provider_offline} end
             )

    assert events(probe) == [:open, :acquire, :close, :cleanup]
  end

  test "cancellation closes and cleans the active cell environment" do
    {:ok, probe} = Agent.start_link(fn -> [] end)
    {:ok, session} = Jidoka.Session.start(spec(), "cancelled-environment")
    parent = self()

    assert {:ok, sequence} =
             Jidoka.Session.run_sequence_async(session, ["wait"],
               execution_environment: resolved_environment(),
               execution_environment_policy: allow_policy(),
               execution_environment_adapter_opts: [probe: probe],
               llm: fn _intent, _journal, _context ->
                 send(parent, :environment_llm_started)
                 Process.sleep(5_000)
                 {:ok, %{type: :final, content: "late"}}
               end
             )

    assert_receive :environment_llm_started, 1_000
    assert {:ok, cancellation} = Jidoka.cancel(sequence, grace_ms: 250)

    assert {:cancelled, ^cancellation, %Sequence.Result{status: :cancelled}} =
             Jidoka.await(sequence, timeout: 1_000)

    assert events(probe) == [:open, :acquire, :close, :cleanup]
  end

  test "different sequences open different bindings and unprofiled sequences stay unchanged" do
    {:ok, first_probe} = Agent.start_link(fn -> [] end)
    {:ok, second_probe} = Agent.start_link(fn -> [] end)
    {:ok, first} = Jidoka.Session.start(spec(), "first-cell")
    {:ok, second} = Jidoka.Session.start(spec(), "second-cell")

    common = [
      execution_environment: resolved_environment(),
      execution_environment_policy: allow_policy(),
      llm: final_llm()
    ]

    assert {:ok, %{session: %{environment: first_environment}}} =
             Jidoka.Session.run_sequence(
               first,
               ["one"],
               common ++
                 [
                   execution_environment_adapter_opts: [
                     probe: first_probe,
                     resource_ref: "environment-first"
                   ]
                 ]
             )

    assert {:ok, %{session: %{environment: second_environment}}} =
             Jidoka.Session.run_sequence(
               second,
               ["two"],
               common ++
                 [
                   execution_environment_adapter_opts: [
                     probe: second_probe,
                     resource_ref: "environment-second"
                   ]
                 ]
             )

    assert first_environment.binding.resource_ref == "environment-first"
    assert second_environment.binding.resource_ref == "environment-second"

    {:ok, plain} = Jidoka.Session.start(spec(), "plain-cell")

    assert {:ok, %{status: :completed, session: %{environment: nil}}} =
             Jidoka.Session.run_sequence(plain, ["plain"], llm: final_llm())
  end

  defp resolved_environment do
    request = PolicyRequest.new!(profile_id: "restricted")
    {:ok, selection} = ProfileResolver.resolve(request, fn _profile_id, _opts -> {:ok, registration()} end)
    %{selection: selection}
  end

  defp registration do
    profile =
      SecurityProfile.new!(
        profile_id: "restricted",
        revision: 1,
        digest: @digest,
        adapter_id: "test.sequence-adapter",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral,
        required_image_digest: @image_digest,
        checkpoint_required: true,
        retention: :ephemeral
      )

    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.sequence-adapter",
        adapter_version: "1",
        isolations: [:container],
        networks: [:disabled],
        workspaces: [:ephemeral],
        immutable_image_evidence: true,
        checkpoint: true
      )

    Registration.new!(profile: profile, adapter: Adapter, capabilities: capabilities)
  end

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end

  defp final_llm do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: "done"}} end
  end

  defp spec do
    Jidoka.agent!(
      id: "sequence_environment_agent",
      instructions: "Test one constrained cell.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp events(probe), do: probe |> Agent.get(&Enum.reverse/1)
end
