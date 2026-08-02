defmodule JidokaExamples.GovernedToolsTest do
  use ExUnit.Case, async: false

  alias Jidoka.Effect.OperationResult
  alias JidokaExamples.GovernedTools.{Agent, Scenario}

  @moduletag example: :governed_tools
  @moduletag timeout: 10_000

  @tag :schema_derived_tools
  @tag :skill_bundle
  @tag :static_tool_narrowing
  test "compiles one stable governed tool contract" do
    assert {:ok, contract} = Scenario.tool_contract()
    assert contract.operations == contract.expected_operations

    assert contract.skill_metadata["name"] == "governed-research"
    assert contract.skill_metadata["allowed_tools"] == ["research_policy_lookup"]

    policy = Enum.find(Agent.spec().operations, &(&1.name == "research_policy_lookup"))
    assert policy.metadata["source"] == "skill"
    assert policy.metadata["parameters_schema"].required == [:topic]

    assert Enum.map(contract.preflight.prompt.operations, & &1.name) |> Enum.sort() ==
             contract.expected_operations
  end

  @tag :schema_derived_tools
  @tag :skill_bundle
  test "executes a skill action through the normal operation boundary" do
    assert {:ok, result} = Scenario.skill_round_trip(observer: self())
    assert_receive {:research_policy_called, "Jidoka tool safety"}

    assert result.content == "Use approved public sources and cite the source URL."

    assert [
             %OperationResult{
               operation: "research_policy_lookup",
               output: %{"citation_required" => true, "topic" => "Jidoka tool safety"}
             }
           ] = result.agent_state.operation_results
  end

  @tag :catalog_discovery
  test "discovers, describes, and executes one allowlisted catalog action" do
    assert {:ok, result} = Scenario.catalog_round_trip()

    assert Enum.map(result.agent_state.operation_results, & &1.operation) == [
             "catalog_query",
             "catalog_describe",
             "catalog_execute"
           ]

    [query, describe, execute] = result.agent_state.operation_results
    assert query.output["count"] == 1
    assert describe.output["allowed_tools"] == ["research.source.search"]
    assert execute.output["status"] == "completed"
    assert execute.output["call_count"] == 1
    assert [%{"tool" => "research.source.search", "status" => "ok"}] = execute.output["calls"]
  end

  @tag :read_only_browser_tools
  test "reads one allowlisted public page through deterministic browser actions" do
    assert {:ok, result} = Scenario.browser_round_trip()
    assert result.content =~ "typed schemas, explicit controls, and deterministic effects"

    assert [%OperationResult{operation: "read_page", output: output}] =
             result.agent_state.operation_results

    assert output["url"] == "https://docs.example.com/guides/tools-and-operations"
    assert output["content"] =~ "typed schemas"

    browser = Enum.filter(Agent.spec().operations, &(&1.metadata["source"] == "browser"))
    assert Enum.map(browser, & &1.name) |> Enum.sort() == ~w(read_page search_web snapshot_url)
    assert Enum.all?(browser, &(&1.metadata["mode"] == "read_only"))
    refute Enum.any?(browser, &(&1.name in ~w(click type submit)))
  end

  @tag :deterministic_evals
  @tag :repeatable_eval_cases
  @tag :trajectory_assertions
  test "runs repeatable cases and fails correct prose with the wrong trajectory" do
    assert {:ok, report} = Scenario.evaluation_suite()
    assert Enum.map(report.runs, &{&1.case_id, &1.status}) == [
             {"governed_tools_required_trajectory", :passed},
             {"governed_tools_missing_trajectory", :failed}
           ]

    assert report.trajectory_scores == %{
             "governed_tools_missing_trajectory" => 0.0,
             "governed_tools_required_trajectory" => 1.0
           }

    failed = Enum.at(report.runs, 1)
    assert Enum.find(failed.assertions, &(&1.name == :contains)).status == :passed
    assert Enum.find(failed.assertions, &(&1.name == :operation_called)).status == :failed
  end

  @tag :local_developer_notebook
  test "renders preflight and graph evidence through the development-only Kino layer" do
    assert {:ok, evidence} = Scenario.notebook_evidence()
    assert evidence.preflight.agent.id == "governed_tools"
    assert evidence.diagram =~ "flowchart"
    assert evidence.diagram =~ "research_policy_lookup"
    assert evidence.diagram =~ "catalog_query"
    assert evidence.diagram =~ "read_page"
  end
end
