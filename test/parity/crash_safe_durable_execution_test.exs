defmodule Jidoka.Parity.CrashSafeDurableExecutionTest do
  use Jidoka.ParityCase, parity: :crash_safe_durable_execution

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.Store
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  @moduletag :e07

  test "recovery replays a completed unsafe result after the first worker crashes" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 100 end)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}
    spec = durable_spec()
    llm = durable_llm()

    assert {:ok, %Session{}} = Jidoka.Session.start(spec, "sess_completed_crash", store: store)

    operations =
      LocalOperations.operations(%{
        refund_order: fn _intent, _journal, _ctx ->
          Elixir.Agent.update(calls, &(&1 + 1))
          {:ok, %{"refund_id" => "refund_123", "status" => "queued"}}
        end
      })

    checkpoint_hook = fn stage, %AgentSnapshot{} = snapshot, _stored ->
      if stage == :result and snapshot.cursor.metadata["effect_kind"] == :operation do
        send(test_pid, {:operation_result_durable, snapshot})

        receive do
          :acknowledge_result -> :ok
        end
      else
        :ok
      end
    end

    worker =
      Task.async(fn ->
        Jidoka.Session.run("sess_completed_crash", "Refund order_123",
          store: store,
          llm: llm,
          operations: operations,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "worker_one",
          on_durable_checkpoint: checkpoint_hook
        )
      end)

    assert_receive {:operation_result_durable, %AgentSnapshot{} = durable_snapshot}, 1_000
    assert operation_result_recorded?(durable_snapshot)
    assert Elixir.Agent.get(calls, & &1) == 1

    assert {:ok, %Session{status: :running, snapshots: snapshots}} =
             Store.get_session(store, "sess_completed_crash")

    assert operation_result_recorded?(List.last(snapshots))
    assert nil == Task.shutdown(worker, :brutal_kill)

    Elixir.Agent.update(clock, fn _now -> 200 end)

    assert {:ok, [%Session{session_id: "sess_completed_crash"}]} =
             Jidoka.Session.recoverable(store, clock: current_clock(clock))

    operations_must_not_repeat = fn _intent, _journal, _ctx ->
      flunk("the completed unsafe operation must not run during recovery")
    end

    assert {:ok, %Session{status: :finished, lease: nil}, %Turn.Result{content: "Refund refund_123 is queued."}} =
             Jidoka.Session.recover("sess_completed_crash",
               store: store,
               llm: llm,
               operations: operations_must_not_repeat,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "worker_two"
             )

    assert Elixir.Agent.get(calls, & &1) == 1
  end

  test "recovery stops for reconciliation when an unsafe result is missing" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 1_000 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}
    spec = durable_spec()
    llm = durable_llm()

    assert {:ok, %Session{}} = Jidoka.Session.start(spec, "sess_incomplete_crash", store: store)

    blocking_operations =
      LocalOperations.operations(%{
        refund_order: fn _intent, _journal, _ctx ->
          send(test_pid, {:unsafe_operation_started, self()})

          receive do
            :finish_unsafe_operation -> {:ok, %{"refund_id" => "must_not_finish"}}
          end
        end
      })

    worker =
      Task.async(fn ->
        Jidoka.Session.run("sess_incomplete_crash", "Refund order_123",
          store: store,
          llm: llm,
          operations: blocking_operations,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "worker_one"
        )
      end)

    assert_receive {:unsafe_operation_started, operation_pid}, 1_000

    assert {:ok, %Session{status: :running, snapshots: snapshots}} =
             Store.get_session(store, "sess_incomplete_crash")

    assert incomplete_unsafe_intent?(List.last(snapshots))
    assert nil == Task.shutdown(worker, :brutal_kill)
    refute Process.alive?(operation_pid)

    Elixir.Agent.update(clock, fn _now -> 1_100 end)

    recovery_operations = fn _intent, _journal, _ctx ->
      send(test_pid, :unsafe_operation_repeated)
      {:ok, %{}}
    end

    assert {:error,
            %ExecutionError{
              phase: :effect,
              details: %{reason: :unsafe_once_incomplete_effect, idempotency: :unsafe_once}
            }} =
             Jidoka.Session.recover("sess_incomplete_crash",
               store: store,
               llm: llm,
               operations: recovery_operations,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "worker_two"
             )

    refute_received :unsafe_operation_repeated

    assert {:ok, %Session{status: :error, lease: nil, error: %ExecutionError{}}} =
             Store.get_session(store, "sess_incomplete_crash")
  end

  test "recovery restarts a claimed request when no effect snapshot exists" do
    {:ok, clock} = Elixir.Agent.start_link(fn -> 500 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}
    spec = chat_spec()
    request = Turn.Request.new!(input: "Answer after recovery", request_id: "turn_early_crash")

    assert {:ok, %Session{}} = Jidoka.Session.start(spec, "sess_early_crash", store: store)

    assert {:ok, %Session{status: :running, snapshots: []}} =
             Store.claim_session(store, "sess_early_crash", request,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               owner_id: "worker_one"
             )

    Elixir.Agent.update(clock, fn _now -> 600 end)

    assert {:ok, [%Session{session_id: "sess_early_crash"}]} =
             Jidoka.Session.recoverable(store, clock: current_clock(clock))

    assert {:ok,
            %Session{
              status: :finished,
              lease: nil,
              requests: [%Turn.Request{request_id: "turn_early_crash"}]
            }, %Turn.Result{content: "request restarted safely"}} =
             Jidoka.Session.recover("sess_early_crash",
               store: store,
               llm: fn _intent, _journal, _ctx ->
                 {:ok, %{type: :final, content: "request restarted safely"}}
               end,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "worker_two"
             )
  end

  defp durable_spec do
    Agent.Spec.new!(
      id: "crash_safe_agent",
      instructions: "Use refund_order, then report the durable result.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "refund_order",
          description: "Starts one refund.",
          idempotency: :unsafe_once
        )
      ],
      controls:
        Controls.new!(
          operations: [
            %{control: ApprovalControl, match: %{name: "refund_order"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp chat_spec do
    Agent.Spec.new!(
      id: "early_crash_agent",
      instructions: "Answer after recovery.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp durable_llm do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "refund_order",
             arguments: %{"order_id" => "order_123"}
           }}

        _count ->
          {:ok, %{type: :final, content: "Refund refund_123 is queued."}}
      end
    end
  end

  defp operation_result_recorded?(%AgentSnapshot{turn_state: %{journal: journal}}) do
    Enum.any?(journal.results, fn {_id, result} -> result.kind == :operation end)
  end

  defp incomplete_unsafe_intent?(%AgentSnapshot{turn_state: %{journal: journal}}) do
    Enum.any?(journal.intents, fn {id, intent} ->
      intent.kind == :operation and intent.idempotency == :unsafe_once and
        not Map.has_key?(journal.results, id)
    end)
  end

  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
