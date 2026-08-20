defmodule Jidoka.SubagentTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Turn

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule EvidenceLookupAction do
    @moduledoc false

    use Jidoka.Action,
      name: "lookup_evidence",
      description: "Looks up delegated evidence.",
      schema: Zoi.object(%{topic: Zoi.string()})

    @impl true
    def run(params, _context) do
      {:ok, %{topic: params[:topic] || params["topic"], evidence: "confirmed"}}
    end
  end

  defmodule ApprovedEvidenceAction do
    @moduledoc false

    use Jidoka.Action,
      name: "approved_evidence",
      description: "Returns evidence after review.",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context), do: {:ok, %{evidence: "approved"}}
  end

  defmodule EvidenceAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :evidence_agent do
      model %{provider: :test, id: "model"}
      instructions "Answer with bounded evidence."
    end
  end

  defmodule IterativeEvidenceAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :iterative_evidence_agent do
      model %{provider: :test, id: "model"}
      instructions "Use lookup_evidence before returning evidence."
    end

    controls do
      max_turns 3
    end

    tools do
      action EvidenceLookupAction
    end
  end

  defmodule ReviewEvidenceAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :review_evidence_agent do
      model %{provider: :test, id: "model"}
      instructions "Use the reviewed evidence operation."
    end

    tools do
      action(ApprovedEvidenceAction,
        idempotency: :unsafe_once,
        approval: [reason: "child_evidence_review"]
      )
    end
  end

  defmodule ParentAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :parent_agent do
      model %{provider: :test, id: "model"}
      instructions "Delegate evidence collection before answering."
    end

    tools do
      subagent EvidenceAgent,
        as: :evidence_specialist,
        description: "Collects bounded evidence for the parent agent.",
        forward_context: {:only, [:tenant]},
        result: :structured
    end
  end

  defmodule IterativeParentAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :iterative_parent_agent do
      model %{provider: :test, id: "model"}
      instructions "Delegate to the iterative evidence agent before answering."
    end

    tools do
      subagent IterativeEvidenceAgent,
        as: :iterative_evidence,
        description: "Runs a bounded child loop and returns evidence.",
        result: :structured
    end
  end

  defmodule ReviewParentAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :review_parent_agent do
      model %{provider: :test, id: "model"}
      instructions "Delegate reviewed evidence work."
    end

    tools do
      subagent ReviewEvidenceAgent,
        as: :review_evidence_specialist,
        result: :structured
    end
  end

  defmodule ParallelReviewParentAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :parallel_review_parent_agent do
      model %{provider: :test, id: "model"}
      instructions "Delegate two independent reviewed evidence tasks."
    end

    tools do
      subagent ReviewEvidenceAgent,
        as: :first_review_specialist,
        result: :structured

      subagent ReviewEvidenceAgent,
        as: :second_review_specialist,
        result: :structured
    end
  end

  test "subagents compile into operation specs and metadata" do
    assert [
             %Operation{
               name: "evidence_specialist",
               metadata: %{
                 "source" => "subagent",
                 "kind" => "subagent",
                 "agent" => agent,
                 "parameters_schema" => %{"required" => ["task"]}
               }
             } = operation
           ] = ParentAgent.spec().operations

    assert agent =~ "EvidenceAgent"
    assert Operation.kind(operation) == :subagent

    assert [
             %{
               "source" => "subagent",
               "name" => "evidence_specialist",
               "agent" => source_agent
             }
           ] = ParentAgent.spec().metadata["tool_sources"]

    assert source_agent =~ "EvidenceAgent"
  end

  test "subagent operations execute a child Jidoka turn" do
    test_pid = self()

    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, ctx ->
      send(test_pid, {:llm_called, payload.agent_id, payload.prompt.context, Jidoka.Context.runtime(ctx)})

      case {payload.agent_id, count_results(journal, :llm)} do
        {"parent_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "evidence_specialist",
             arguments: %{
               "task" => "Find evidence for the answer.",
               "context" => %{"task_scope" => "runtime"}
             }
           }}

        {"parent_agent", 1} ->
          {:ok, %{type: :final, content: "Parent answer uses child evidence."}}

        {"evidence_agent", 0} ->
          {:ok, %{type: :final, content: "Child evidence confirms the answer."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Should I delegate?",
        context: %{tenant: "acme", secret: "hidden"}
      )

    assert {:ok, %Turn.Result{} = result} =
             ParentAgent.run_turn(request,
               llm: llm,
               operation_context: %{subagent_llm: llm}
             )

    assert result.content == "Parent answer uses child evidence."

    assert [
             %Effect.OperationResult{
               operation: "evidence_specialist",
               output: %{
                 subagent: "evidence_specialist",
                 content: "Child evidence confirms the answer."
               }
             }
           ] = result.agent_state.operation_results

    assert_receive {:llm_called, "parent_agent", %{}, %{}}

    assert_receive {:llm_called, "evidence_agent", %{:tenant => "acme", "task_scope" => "runtime"}, %{}}

    refute_received {:llm_called, "evidence_agent", %{secret: "hidden"}, _runtime}
  end

  test "subagents delegate a bounded child loop and return results to the parent" do
    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _ctx ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"iterative_parent_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "iterative_evidence",
             arguments: %{"task" => "Find evidence for Runic."}
           }}

        {"iterative_parent_agent", 1} ->
          {:ok, %{type: :final, content: "Parent synthesized child evidence."}}

        {"iterative_evidence_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "lookup_evidence",
             arguments: %{"topic" => "Runic"}
           }}

        {"iterative_evidence_agent", 1} ->
          {:ok, %{type: :final, content: "Child found confirmed evidence."}}
      end
    end

    assert {:ok, %Turn.Result{content: "Parent synthesized child evidence."} = result} =
             IterativeParentAgent.run_turn("Should I delegate?",
               llm: llm,
               operation_context: %{subagent_llm: llm}
             )

    assert [
             %Effect.OperationResult{
               operation: "iterative_evidence",
               output: %{
                 subagent: "iterative_evidence",
                 content: "Child found confirmed evidence.",
                 operation_results: [
                   %{operation: "lookup_evidence", output: %{"evidence" => "confirmed"}}
                 ]
               }
             }
           ] = result.agent_state.operation_results
  end

  test "a parent turn preserves and resumes a suspended subagent operation" do
    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _ctx ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"parent_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "evidence_specialist",
             arguments: %{"task" => "Collect durable evidence."}
           }}

        {"parent_agent", 1} ->
          {:ok, %{type: :final, content: "Parent resumed the child result."}}

        {"evidence_agent", 0} ->
          {:ok, %{type: :final, content: "Durable child evidence."}}
      end
    end

    assert {:hibernate, snapshot} =
             ParentAgent.run_turn("Delegate durable work.",
               llm: llm,
               operation_context: %{
                 subagent_llm: llm,
                 subagent_opts: [checkpoint: :before_each_effect]
               }
             )

    assert snapshot.cursor.phase == :wait

    assert [
             %Jidoka.Operation.Continuation{
               kind: :subagent,
               operation: "evidence_specialist"
             }
           ] = snapshot.metadata["operation_continuations"]

    assert {:ok, restored_snapshot} =
             snapshot
             |> Jidoka.Snapshot.serialize!()
             |> Jidoka.Snapshot.deserialize()

    assert {:ok, %Turn.Result{content: "Parent resumed the child result."} = result} =
             Jidoka.Harness.resume(restored_snapshot,
               llm: llm,
               operation_context: %{subagent_llm: llm},
               nested_resume_opts: [checkpoint: :none]
             )

    assert [operation_result] = result.agent_state.operation_results
    assert operation_result.operation == "evidence_specialist"
    assert operation_result.output.content == "Durable child evidence."
  end

  test "parent review APIs expose and approve a nested subagent review" do
    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _ctx ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"review_parent_agent", 0} ->
          {:ok,
           %{
             type: :operation,
             name: "review_evidence_specialist",
             arguments: %{"task" => "Collect reviewed evidence."}
           }}

        {"review_parent_agent", 1} ->
          {:ok, %{type: :final, content: "Parent received approved evidence."}}

        {"review_evidence_agent", 0} ->
          {:ok, %{type: :operation, name: "approved_evidence", arguments: %{}}}

        {"review_evidence_agent", 1} ->
          {:ok, %{type: :final, content: "Child evidence was approved."}}
      end
    end

    assert {:hibernate, snapshot} =
             ReviewParentAgent.run_turn("Delegate reviewed work.",
               llm: llm,
               operation_context: %{subagent_llm: llm}
             )

    assert {:ok, [review]} = Jidoka.pending_reviews(snapshot)
    assert review.agent_id == "review_evidence_agent"
    assert review.operation == "approved_evidence"

    assert {:ok, %Turn.Result{content: "Parent received approved evidence."} = result} =
             Jidoka.approve(snapshot, review,
               llm: llm,
               operation_context: %{subagent_llm: llm}
             )

    assert [parent_operation] = result.agent_state.operation_results
    assert parent_operation.operation == "review_evidence_specialist"
    assert parent_operation.output.content == "Child evidence was approved."
  end

  test "one approval resumes only its matching child in a parallel group" do
    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _ctx ->
      case {payload.agent_id, count_results(journal, :llm)} do
        {"parallel_review_parent_agent", 0} ->
          {:ok,
           %{
             type: :operations,
             operations: [
               %{name: "first_review_specialist", arguments: %{"task" => "First review."}},
               %{name: "second_review_specialist", arguments: %{"task" => "Second review."}}
             ]
           }}

        {"parallel_review_parent_agent", 1} ->
          {:ok, %{type: :final, content: "Both child reviews completed."}}

        {"review_evidence_agent", 0} ->
          {:ok, %{type: :operation, name: "approved_evidence", arguments: %{}}}

        {"review_evidence_agent", 1} ->
          {:ok, %{type: :final, content: "Child evidence was approved."}}
      end
    end

    opts = [llm: llm, operation_context: %{subagent_llm: llm}]

    assert {:hibernate, snapshot} =
             ParallelReviewParentAgent.run_turn("Run both reviews.", opts)

    assert {:ok, [first_review, second_review]} = Jidoka.pending_reviews(snapshot)
    assert first_review.interrupt_id != second_review.interrupt_id

    assert {:hibernate, remaining_snapshot} = Jidoka.approve(snapshot, first_review, opts)
    assert {:ok, [remaining_review]} = Jidoka.pending_reviews(remaining_snapshot)
    assert remaining_review.interrupt_id == second_review.interrupt_id

    assert {:ok, %Turn.Result{content: "Both child reviews completed."}} =
             Jidoka.approve(remaining_snapshot, remaining_review, opts)
  end
end
