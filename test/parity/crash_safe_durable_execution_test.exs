defmodule Jidoka.Parity.CrashSafeDurableExecutionTest do
  use Jidoka.ParityCase, parity: :crash_safe_durable_execution

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Error.ExecutionError
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Session.Store
  alias Jidoka.Session.Store.InMemory
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.Snapshot
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

    checkpoint_hook = fn stage, %Snapshot{} = snapshot, _stored ->
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

    assert_receive {:operation_result_durable, %Snapshot{} = durable_snapshot}, 1_000
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

  test "batch recovery replays a completed unsafe call and resumes its incomplete sibling" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 2_000 end)
    {:ok, unsafe_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, idempotent_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    assert {:ok, %Session{}} =
             Jidoka.Session.start(durable_batch_spec(), "sess_batch_crash", store: store)

    operations =
      LocalOperations.operations(%{
        charge_order: fn _intent, _journal, _ctx ->
          Elixir.Agent.update(unsafe_calls, &(&1 + 1))
          send(test_pid, {:unsafe_batch_call_started, self()})

          receive do
            :finish_unsafe_batch_call ->
              {:ok, %{"charge_id" => "charge_123", "status" => "queued"}}
          end
        end,
        lookup_receipt: fn _intent, _journal, _ctx ->
          Elixir.Agent.update(idempotent_calls, &(&1 + 1))
          send(test_pid, {:idempotent_batch_call_started, self()})

          receive do
            :finish_idempotent_batch_call ->
              {:ok, %{"receipt_id" => "receipt_123"}}
          end
        end
      })

    checkpoint_hook = fn stage, %Snapshot{} = snapshot, _stored ->
      if snapshot.cursor.metadata["effect_kind"] == :operation do
        send(test_pid, {:batch_checkpoint, stage, checkpoint_operation(snapshot)})

        if stage == :result and checkpoint_operation(snapshot) == "charge_order" do
          send(test_pid, {:unsafe_batch_result_durable, snapshot})

          receive do
            :release_batch_checkpoint -> :ok
          end
        end
      end

      :ok
    end

    worker =
      Task.async(fn ->
        Jidoka.Session.run("sess_batch_crash", "Charge and look up the receipt.",
          store: store,
          llm: durable_batch_llm(),
          operations: operations,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "batch_worker_one",
          max_parallel_operations: 2,
          on_durable_checkpoint: checkpoint_hook
        )
      end)

    assert_receive {:unsafe_batch_call_started, unsafe_pid}, 1_000
    assert_receive {:idempotent_batch_call_started, _idempotent_pid}, 1_000
    send(unsafe_pid, :finish_unsafe_batch_call)

    assert_receive {:unsafe_batch_result_durable, %Snapshot{} = durable_snapshot}, 1_000

    assert_receive {:batch_checkpoint, :operation_group, _operation}

    intent_checkpoints =
      Enum.map(1..2, fn _index ->
        assert_receive {:batch_checkpoint, :intent, operation}
        operation
      end)

    assert Enum.sort(intent_checkpoints) == ["charge_order", "lookup_receipt"]
    assert_receive {:batch_checkpoint, :result, "charge_order"}

    assert [group] = Map.values(durable_snapshot.turn_state.journal.operation_groups)
    assert group.status == :running
    assert group.started_intent_ids == group.intent_ids
    assert length(group.completed_intent_ids) == 1
    assert completed_operation_names(durable_snapshot, group) == ["charge_order"]
    assert nil == Task.shutdown(worker, :brutal_kill)

    Elixir.Agent.update(clock, fn _now -> 2_100 end)

    recovery_operations =
      LocalOperations.operations(%{
        charge_order: fn _intent, _journal, _ctx ->
          flunk("the completed unsafe batch call must not repeat")
        end,
        lookup_receipt: fn _intent, _journal, _ctx ->
          Elixir.Agent.update(idempotent_calls, &(&1 + 1))
          {:ok, %{"receipt_id" => "receipt_123"}}
        end
      })

    assert {:ok, %Session{status: :finished}, %Turn.Result{content: "Charge and receipt are durable."}} =
             Jidoka.Session.recover("sess_batch_crash",
               store: store,
               llm: durable_batch_llm(),
               operations: recovery_operations,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "batch_worker_two",
               max_parallel_operations: 2
             )

    assert Elixir.Agent.get(unsafe_calls, & &1) == 1
    assert Elixir.Agent.get(idempotent_calls, & &1) == 2

    assert {:ok, stored} = Store.get_session(store, "sess_batch_crash")
    final_snapshot = List.last(stored.snapshots)
    assert [final_group] = Map.values(final_snapshot.turn_state.journal.operation_groups)
    assert final_group.status == :completed
    assert final_group.completed_intent_ids == final_group.intent_ids
  end

  test "batch recovery restarts all calls after a manifest-boundary crash" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 3_000 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    assert {:ok, %Session{}} =
             Jidoka.Session.start(idempotent_batch_spec(), "sess_batch_manifest_crash", store: store)

    checkpoint_hook = fn stage, %Snapshot{} = snapshot, _stored ->
      if stage == :operation_group and snapshot.cursor.metadata["effect_kind"] == :operation do
        send(test_pid, {:batch_manifest_durable, snapshot})

        receive do
          :release_manifest_checkpoint -> :ok
        end
      end

      :ok
    end

    operations_must_wait =
      LocalOperations.operations(%{
        read_alpha: fn _intent, _journal, _ctx ->
          send(test_pid, :manifest_alpha_called_early)
          {:ok, %{}}
        end,
        read_beta: fn _intent, _journal, _ctx ->
          send(test_pid, :manifest_beta_called_early)
          {:ok, %{}}
        end
      })

    worker =
      Task.async(fn ->
        Jidoka.Session.run("sess_batch_manifest_crash", "Read both values.",
          store: store,
          llm: idempotent_batch_llm(),
          operations: operations_must_wait,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "manifest_worker_one",
          on_durable_checkpoint: checkpoint_hook
        )
      end)

    assert_receive {:batch_manifest_durable, %Snapshot{} = manifest_snapshot}, 1_000
    refute_received :manifest_alpha_called_early
    refute_received :manifest_beta_called_early

    assert [manifest] = Map.values(manifest_snapshot.turn_state.journal.operation_groups)
    assert manifest.status == :planned
    assert manifest.started_intent_ids == []
    assert manifest.completed_intent_ids == []

    refute Enum.any?(manifest_snapshot.turn_state.journal.intents, fn {_id, intent} ->
             intent.kind == :operation
           end)

    assert nil == Task.shutdown(worker, :brutal_kill)

    Elixir.Agent.update(clock, fn _now -> 3_100 end)

    recovery_operations =
      LocalOperations.operations(%{
        read_alpha: fn _intent, _journal, _ctx ->
          send(test_pid, :manifest_alpha_recovered)
          {:ok, %{"value" => "alpha"}}
        end,
        read_beta: fn _intent, _journal, _ctx ->
          send(test_pid, :manifest_beta_recovered)
          {:ok, %{"value" => "beta"}}
        end
      })

    assert {:ok, %Session{status: :finished}, %Turn.Result{content: "Both values are durable."}} =
             Jidoka.Session.recover("sess_batch_manifest_crash",
               store: store,
               llm: idempotent_batch_llm(),
               operations: recovery_operations,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "manifest_worker_two"
             )

    assert_receive :manifest_alpha_recovered
    assert_receive :manifest_beta_recovered
  end

  test "an intent-boundary crash blocks incomplete unsafe batch calls" do
    test_pid = self()
    {:ok, clock} = Elixir.Agent.start_link(fn -> 4_000 end)
    {:ok, store_pid} = InMemory.start_link()
    store = {InMemory, pid: store_pid}

    assert {:ok, %Session{}} =
             Jidoka.Session.start(two_unsafe_batch_spec(), "sess_batch_intent_crash", store: store)

    checkpoint_hook = fn stage, %Snapshot{} = snapshot, _stored ->
      if stage == :intent and snapshot.cursor.metadata["effect_kind"] == :operation do
        send(test_pid, {:unsafe_batch_intent_durable, snapshot})

        receive do
          :release_unsafe_intent_checkpoint -> :ok
        end
      end

      :ok
    end

    operations_must_not_start =
      LocalOperations.operations(%{
        charge_primary: fn _intent, _journal, _ctx ->
          send(test_pid, :primary_unsafe_started)
          {:ok, %{}}
        end,
        charge_secondary: fn _intent, _journal, _ctx ->
          send(test_pid, :secondary_unsafe_started)
          {:ok, %{}}
        end
      })

    worker =
      Task.async(fn ->
        Jidoka.Session.run("sess_batch_intent_crash", "Run both unsafe calls.",
          store: store,
          llm: two_unsafe_batch_llm(),
          operations: operations_must_not_start,
          clock: current_clock(clock),
          lease_ttl_ms: 100,
          lease_heartbeat: false,
          owner_id: "intent_worker_one",
          max_parallel_operations: 2,
          on_durable_checkpoint: checkpoint_hook
        )
      end)

    assert_receive {:unsafe_batch_intent_durable, %Snapshot{} = intent_snapshot}, 1_000
    refute_received :primary_unsafe_started
    refute_received :secondary_unsafe_started

    assert [group] = Map.values(intent_snapshot.turn_state.journal.operation_groups)
    assert group.status == :running
    assert length(group.started_intent_ids) == 1
    assert group.completed_intent_ids == []
    assert nil == Task.shutdown(worker, :brutal_kill)

    Elixir.Agent.update(clock, fn _now -> 4_100 end)

    recovery_operations = fn _intent, _journal, _ctx ->
      send(test_pid, :unsafe_batch_call_repeated)
      {:ok, %{}}
    end

    assert {:error,
            %ExecutionError{
              phase: :effect,
              details: %{reason: :unsafe_once_incomplete_effect, idempotency: :unsafe_once}
            }} =
             Jidoka.Session.recover("sess_batch_intent_crash",
               store: store,
               llm: two_unsafe_batch_llm(),
               operations: recovery_operations,
               clock: current_clock(clock),
               lease_ttl_ms: 100,
               lease_heartbeat: false,
               owner_id: "intent_worker_two",
               max_parallel_operations: 2
             )

    refute_received :unsafe_batch_call_repeated
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

  defp durable_batch_spec do
    Agent.Spec.new!(
      id: "crash_safe_batch_agent",
      instructions: "Charge once, look up the receipt, and report both results.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(
          name: "charge_order",
          description: "Charges an order once.",
          idempotency: :unsafe_once
        ),
        Operation.new!(
          name: "lookup_receipt",
          description: "Looks up a receipt.",
          idempotency: :idempotent
        )
      ],
      controls:
        Controls.new!(
          operations: [
            %{control: ApprovalControl, match: %{name: "charge_order"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp durable_batch_llm do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 ->
          {:ok,
           %{
             type: :operations,
             operations: [
               %{name: "charge_order", arguments: %{"order_id" => "order_123"}},
               %{name: "lookup_receipt", arguments: %{"order_id" => "order_123"}}
             ]
           }}

        _count ->
          {:ok, %{type: :final, content: "Charge and receipt are durable."}}
      end
    end
  end

  defp idempotent_batch_spec do
    Agent.Spec.new!(
      id: "idempotent_batch_agent",
      instructions: "Read both values and report them.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(name: "read_alpha", idempotency: :idempotent),
        Operation.new!(name: "read_beta", idempotency: :idempotent)
      ],
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp idempotent_batch_llm do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 ->
          {:ok,
           %{
             type: :operations,
             operations: [
               %{name: "read_alpha", arguments: %{}},
               %{name: "read_beta", arguments: %{}}
             ]
           }}

        _count ->
          {:ok, %{type: :final, content: "Both values are durable."}}
      end
    end
  end

  defp two_unsafe_batch_spec do
    Agent.Spec.new!(
      id: "two_unsafe_batch_agent",
      instructions: "Run both unsafe calls once.",
      model: %{provider: :test, id: "model"},
      operations: [
        Operation.new!(name: "charge_primary", idempotency: :unsafe_once),
        Operation.new!(name: "charge_secondary", idempotency: :unsafe_once)
      ],
      controls:
        Controls.new!(
          operations: [
            %{control: ApprovalControl, match: %{name: "charge_primary"}},
            %{control: ApprovalControl, match: %{name: "charge_secondary"}}
          ]
        ),
      runtime_defaults: %{max_model_turns: 4}
    )
  end

  defp two_unsafe_batch_llm do
    fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 ->
          {:ok,
           %{
             type: :operations,
             operations: [
               %{name: "charge_primary", arguments: %{}},
               %{name: "charge_secondary", arguments: %{}}
             ]
           }}

        _count ->
          {:ok, %{type: :final, content: "Both unsafe calls completed."}}
      end
    end
  end

  defp operation_result_recorded?(%Snapshot{turn_state: %{journal: journal}}) do
    Enum.any?(journal.results, fn {_id, result} -> result.kind == :operation end)
  end

  defp incomplete_unsafe_intent?(%Snapshot{turn_state: %{journal: journal}}) do
    Enum.any?(journal.intents, fn {id, intent} ->
      intent.kind == :operation and intent.idempotency == :unsafe_once and
        not Map.has_key?(journal.results, id)
    end)
  end

  defp checkpoint_operation(%Snapshot{cursor: %{metadata: metadata}, turn_state: state}) do
    intent_id = metadata["effect_id"]

    (Map.get(state.journal.intents, intent_id) ||
       Enum.find(state.pending_effects, &(&1.id == intent_id)))
    |> then(&Jidoka.Schema.get_key(&1.payload, :name))
  end

  defp completed_operation_names(%Snapshot{turn_state: %{journal: journal}}, group) do
    group.completed_intent_ids
    |> Enum.map(fn intent_id ->
      journal.intents
      |> Map.fetch!(intent_id)
      |> then(&Jidoka.Schema.get_key(&1.payload, :name))
    end)
    |> Enum.sort()
  end

  defp current_clock(clock), do: fn -> Elixir.Agent.get(clock, & &1) end
end
