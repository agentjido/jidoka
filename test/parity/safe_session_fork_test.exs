defmodule Jidoka.Parity.SafeSessionForkTest do
  use Jidoka.ParityCase, parity: :safe_session_fork

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Harness.Session
  alias Jidoka.Harness.SessionLineage
  alias Jidoka.Harness.Store
  alias Jidoka.Harness.Store.InMemory
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2, final_llm: 1]

  @moduletag :e08

  test "a stored snapshot creates independent runnable branches" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    spec = chat_spec()

    assert {:ok, %Session{session_id: "sess_source"}} =
             Jidoka.Session.start(spec, "sess_source", store: store)

    assert {:hibernate, source_before_fork, %AgentSnapshot{} = snapshot} =
             Jidoka.Session.run("sess_source", "Choose a path",
               store: store,
               llm: final_llm("unused"),
               checkpoint: :after_prompt
             )

    assert {:ok, signed_snapshot} = AgentSnapshot.serialize(snapshot)

    assert {:ok,
            %Session{
              session_id: "sess_branch",
              status: :hibernated,
              lineage: %SessionLineage{
                root_session_id: "sess_source",
                parent_session_id: "sess_source",
                source_snapshot_id: source_snapshot_id,
                depth: 1
              }
            } = branch} =
             Jidoka.fork_session("sess_source",
               store: store,
               session_id: "sess_branch",
               snapshot: signed_snapshot,
               fork_snapshot_id: "snap_branch",
               clock: fn -> 100 end
             )

    assert source_snapshot_id == snapshot.snapshot_id
    assert branch.result == nil
    assert {:ok, ^source_before_fork} = Store.get_session(store, "sess_source")

    assert {:ok, source_after_resume, %Turn.Result{content: "source path"}} =
             Jidoka.Session.resume("sess_source", store: store, llm: final_llm("source path"))

    assert {:ok, branch_after_resume, %Turn.Result{content: "branch path"}} =
             Jidoka.Session.resume("sess_branch", store: store, llm: final_llm("branch path"))

    assert source_after_resume.session_id == "sess_source"
    assert branch_after_resume.session_id == "sess_branch"
    assert source_after_resume.lineage == nil
    assert branch_after_resume.lineage == branch.lineage

    assert {:ok, replay} = Jidoka.Session.replay(source_after_resume)
    assert replay.session_id == source_after_resume.session_id
    assert replay.status == :finished
    assert replay.result.content == "source path"
    assert replay.timeline != []
  end

  test "a fork reuses completed unsafe effect evidence without calling the operation" do
    {:ok, pid} = InMemory.start_link()
    store = {InMemory, pid: pid}
    spec = unsafe_spec()
    llm = unsafe_llm()

    assert {:ok, %Session{}} =
             Jidoka.Session.start(spec, "sess_unsafe_source", store: store)

    assert {:hibernate, _session, %AgentSnapshot{cursor: %{phase: :after_prompt}}} =
             Jidoka.Session.run("sess_unsafe_source", "Refund order_123",
               store: store,
               llm: llm,
               checkpoint: :after_each_phase
             )

    assert {:hibernate, %Session{} = source, %AgentSnapshot{cursor: %{phase: :before_effect}} = snapshot} =
             Jidoka.Session.resume("sess_unsafe_source",
               store: store,
               llm: llm,
               operations: rejecting_operations(),
               checkpoint: :after_each_phase
             )

    pending_effect = Turn.State.current_pending_effect(snapshot.turn_state)
    assert %Effect.Intent{kind: :operation, idempotency: :unsafe_once} = pending_effect

    completed_result =
      Effect.Result.ok(pending_effect, %{
        "refund_id" => "refund_123",
        "order_id" => "order_123",
        "status" => "queued"
      })

    journal =
      snapshot.turn_state.journal
      |> Effect.Journal.put_intent(pending_effect)
      |> Effect.Journal.put_result(completed_result)

    completed_snapshot =
      %AgentSnapshot{
        snapshot
        | turn_state: %Turn.State{snapshot.turn_state | journal: journal}
      }

    completed_source =
      %Session{source | snapshots: List.replace_at(source.snapshots, -1, completed_snapshot)}

    assert {:ok, ^completed_source} = Store.put_session(store, completed_source)

    assert {:ok, %Session{} = fork} =
             Jidoka.Session.fork("sess_unsafe_source",
               store: store,
               session_id: "sess_unsafe_branch",
               fork_snapshot_id: "snap_unsafe_branch",
               clock: fn -> 200 end
             )

    assert hd(Enum.reverse(fork.snapshots)).turn_state.journal == journal

    assert {:ok, finished, %Turn.Result{content: "Refund refund_123 is queued."} = result} =
             Jidoka.Session.resume("sess_unsafe_branch",
               store: store,
               llm: llm,
               operations: rejecting_operations()
             )

    assert %Session{status: :finished, lineage: %SessionLineage{depth: 1}} = finished
    assert Effect.Journal.result_for(result.journal, pending_effect) == completed_result
    assert {:ok, ^completed_source} = Store.get_session(store, "sess_unsafe_source")
  end

  defp chat_spec do
    Agent.Spec.new!(
      id: "safe_fork_chat_agent",
      instructions: "Answer with the selected path.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp unsafe_spec do
    Agent.Spec.new!(
      id: "safe_fork_unsafe_agent",
      instructions: "Use refund_order, then report its result.",
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

  defp unsafe_llm do
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

  defp rejecting_operations do
    fn _intent, _journal, _ctx ->
      flunk("the completed unsafe operation must not run again")
    end
  end
end
