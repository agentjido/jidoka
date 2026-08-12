defmodule Jidoka.Runtime.LimitsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Binding
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.Extension.Dispatcher
  alias Jidoka.Extension.Event
  alias Jidoka.Policy.Decision
  alias Jidoka.Runtime.Limits
  alias Jidoka.Session.Sequence

  @profile_digest "sha256:" <> String.duplicate("a", 64)

  defmodule BlockingEnvironment do
    @behaviour Jidoka.ExecutionEnvironment.Adapter

    alias Jidoka.ExecutionEnvironment.Binding
    alias Jidoka.ExecutionEnvironment.EnforcementEvidence

    @impl true
    def open(profile, _request, opts) do
      send(Keyword.fetch!(opts, :owner), {:environment_started, self()})
      Process.sleep(5_000)

      {:ok,
       Binding.new!(
         adapter_id: profile.adapter_id,
         adapter_version: "1",
         profile_id: profile.profile_id,
         profile_digest: profile.digest,
         resource_ref: "late",
         state: :available
       ), evidence()}
    end

    @impl true
    def acquire(_binding, _opts), do: {:error, :not_used}

    @impl true
    def checkpoint(_handle, _binding, _opts), do: {:error, :not_used}

    @impl true
    def restore(_binding, _checkpoint, _opts), do: {:error, :not_used}

    @impl true
    def fork(_binding, _checkpoint, _opts), do: {:error, :not_used}

    @impl true
    def close(_handle, _opts), do: {:ok, evidence()}

    @impl true
    def cleanup(_binding, _opts), do: {:ok, evidence()}

    defp evidence do
      EnforcementEvidence.new!(
        status: :confirmed,
        adapter_id: "test.blocking",
        backend: "test",
        isolation: :container,
        network: :disabled,
        workspace: :ephemeral,
        applied_limits: %{},
        checkpoint: %{},
        observed_at_ms: 1
      )
    end
  end

  test "resolves caller limits only as reductions of the turn plan" do
    plan = Jidoka.plan!(spec())

    assert {:ok, applied} =
             Limits.resolve(plan,
               runtime_limits: %{
                 max_model_turns: 2,
                 turn_timeout_ms: 2_000,
                 capability_timeout_ms: 20,
                 sequence_timeout_ms: 100,
                 max_total_tokens: 50,
                 max_total_cost: 0.5
               }
             )

    assert applied.max_model_turns == 2
    assert applied.turn_timeout_ms == 2_000
    assert applied.capability_timeout_ms == 20
    assert applied.sequence_timeout_ms == 100

    assert {:error, _reason} = Limits.resolve(plan, runtime_limits: %{capability_timeout_ms: 0})
    assert {:error, {:unknown_runtime_limit_keys, [:unknown]}} = Limits.resolve(plan, runtime_limits: %{unknown: 1})
  end

  test "a blocked model call stops at the capability deadline and kills its worker" do
    parent = self()

    llm = fn _intent, _journal, _context ->
      send(parent, {:model_started, self()})
      Process.sleep(5_000)
      {:ok, %{type: :final, content: "late"}}
    end

    assert {:ok,
            %Sequence.Result{
              status: :error,
              limits: %Limits.Evidence{
                status: :exceeded,
                exceeded: %Limits.Exceeded{kind: :capability_timeout, effect_kind: :llm}
              }
            }} =
             run_sequence(spec(), ["wait"],
               llm: llm,
               runtime_limits: %{capability_timeout_ms: 10}
             )

    assert_receive {:model_started, worker}, 1_000
    refute Process.alive?(worker)
  end

  test "a blocked operation call uses the same deadline and kills its worker" do
    parent = self()

    llm = fn _intent, %Effect.Journal{} = journal, _context ->
      if Enum.any?(journal.results, fn {_id, result} -> result.kind == :operation end) do
        {:ok, %{type: :final, content: "done"}}
      else
        {:ok, %{type: :operation, name: "wait", arguments: %{}}}
      end
    end

    operation = fn _intent, _journal, _context ->
      send(parent, {:operation_started, self()})
      Process.sleep(5_000)
      {:ok, %{late: true}}
    end

    assert {:ok,
            %Sequence.Result{
              status: :error,
              limits: %Limits.Evidence{
                status: :exceeded,
                exceeded: %Limits.Exceeded{kind: :capability_timeout, effect_kind: :operation}
              }
            }} =
             run_sequence(spec(operations: [Operation.new!(name: "wait")]), ["wait"],
               llm: llm,
               operations: operation,
               runtime_limits: %{capability_timeout_ms: 10}
             )

    assert_receive {:operation_started, worker}, 1_000
    refute Process.alive?(worker)
  end

  test "an extension subscriber cannot block past the applied capability deadline" do
    parent = self()

    subscriber = fn _event ->
      send(parent, {:extension_started, self()})
      Process.sleep(5_000)
      :ok
    end

    assert {:ok, dispatcher} = Dispatcher.start_link(subscribers: [subscriber], timeout_ms: 5_000)
    event = Event.new!(name: "session.start", session_ref: "limits-extension")
    plan = Jidoka.plan!(spec())
    {:ok, limits} = Limits.resolve(plan, runtime_limits: %{capability_timeout_ms: 10})

    started = System.monotonic_time(:millisecond)

    assert :ok =
             Jidoka.Extension.RuntimeEvents.emit(
               "session.start",
               %{session_ref: "limits-extension", data: %{}},
               extension_dispatcher: dispatcher,
               runtime_limits: limits
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:extension_started, worker}, 1_000
    refute Process.alive?(worker)

    assert {:ok, [%{"status" => "timeout"}]} =
             Dispatcher.dispatch(dispatcher, event, subscriber_timeout_ms: 10)
  end

  test "an environment lifecycle call cannot block past the applied deadline" do
    assert {:ok, session} = Jidoka.Session.start(spec(), "limits-environment")

    assert {:ok,
            %Sequence.Result{
              status: :error,
              terminal: %{
                reason: %ExecutionEnvironment.Error{code: :execution_environment_limit_exceeded}
              },
              limits: %Limits.Evidence{
                status: :exceeded,
                exceeded: %Limits.Exceeded{
                  kind: :capability_timeout,
                  effect_kind: :execution_environment
                }
              }
            }} =
             Jidoka.Session.run_sequence(session, ["wait"],
               execution_environment: resolved_environment(),
               execution_environment_policy: allow_policy(),
               execution_environment_adapter_opts: [owner: self()],
               llm: final_llm(),
               runtime_limits: %{capability_timeout_ms: 10}
             )

    assert_receive {:environment_started, worker}, 1_000
    refute Process.alive?(worker)
  end

  test "a cumulative token budget stops later work and returns observed evidence" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    llm = fn _intent, _journal, _context ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      {:ok,
       %{
         type: :final,
         content: "answer-#{call}",
         metadata: %{usage: %{input_tokens: 4, output_tokens: 3, total_tokens: 7}}
       }}
    end

    assert {:ok,
            %Sequence.Result{
              status: :error,
              steps: [_, _],
              terminal: %{index: 2},
              limits: %Limits.Evidence{
                status: :exceeded,
                observed: %{usage: %{total_tokens: 14}},
                exceeded: %Limits.Exceeded{kind: :total_tokens, limit: 10, observed: 14}
              }
            }} =
             run_sequence(spec(), ["one", "two", "never"],
               llm: llm,
               runtime_limits: %{max_total_tokens: 10}
             )

    assert Agent.get(calls, & &1) == 2
  end

  test "a sequence deadline stops before the next turn with portable evidence" do
    {:ok, session} = Jidoka.Session.start(spec(), "limits-deadline")
    {:ok, clock} = Agent.start_link(fn -> [0, 0, 11, 11] end)

    now = fn ->
      Agent.get_and_update(clock, fn
        [next | rest] -> {next, rest}
        [] -> {11, []}
      end)
    end

    assert {:ok,
            %Sequence.Result{
              status: :error,
              steps: [_],
              terminal: %{index: 2},
              limits: %Limits.Evidence{
                status: :exceeded,
                exceeded: %Limits.Exceeded{kind: :sequence_timeout, limit: 10}
              }
            }} =
             Jidoka.Session.run_sequence(session, ["one", "never"],
               llm: final_llm(),
               clock: now,
               runtime_limits: %{sequence_timeout_ms: 10}
             )
  end

  defp run_sequence(spec, inputs, opts) do
    {:ok, session} = Jidoka.Session.start(spec, "limits-#{System.unique_integer([:positive])}")
    Jidoka.Session.run_sequence(session, inputs, opts)
  end

  defp spec(overrides \\ []) do
    defaults = [
      id: "runtime_limits_agent",
      instructions: "Return a short answer.",
      model: %{provider: :test, id: "model"},
      runtime_defaults: %{max_model_turns: 4, timeout_ms: 5_000}
    ]

    Jidoka.agent!(Keyword.merge(defaults, overrides))
  end

  defp final_llm do
    fn _intent, _journal, _context -> {:ok, %{type: :final, content: "done"}} end
  end

  defp resolved_environment do
    profile =
      SecurityProfile.new!(
        profile_id: "blocking",
        revision: 1,
        digest: @profile_digest,
        adapter_id: "test.blocking",
        required_isolation: :container,
        required_network: :disabled,
        required_workspace: :ephemeral
      )

    capabilities =
      AdapterCapabilities.new!(
        adapter_id: "test.blocking",
        adapter_version: "1",
        isolations: [:container],
        networks: [:disabled],
        workspaces: [:ephemeral]
      )

    %{
      request: PolicyRequest.new!(profile_id: "blocking"),
      registration: Registration.new!(profile: profile, adapter: BlockingEnvironment, capabilities: capabilities)
    }
  end

  defp allow_policy do
    fn _request, _context -> {:ok, Decision.new!(outcome: :allow, rule_id: "test.allow")} end
  end
end
