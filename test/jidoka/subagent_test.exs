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

    llm = fn %Effect.Intent{payload: payload}, %Effect.Journal{} = journal, _ctx ->
      send(test_pid, {:llm_called, payload.agent_id, payload.prompt.context})

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

    assert_receive {:llm_called, "parent_agent", %{}}

    assert_receive {:llm_called, "evidence_agent", %{:tenant => "acme", "task_scope" => "runtime"}}

    refute_received {:llm_called, "evidence_agent", %{secret: "hidden"}}
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
end
