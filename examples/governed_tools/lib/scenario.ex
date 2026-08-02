defmodule JidokaExamples.GovernedTools.Scenario do
  @moduledoc false

  alias Jidoka.Eval
  alias Jidoka.Turn
  alias JidokaExamples.GovernedTools.{Agent, BrowserDoubles, ScriptedLLM}

  @expected_operations ~w(
    catalog_describe
    catalog_execute
    catalog_query
    read_page
    research_policy_lookup
    search_web
    snapshot_url
  )

  def run do
    with {:ok, contract} <- tool_contract(),
         {:ok, skill} <- skill_round_trip(),
         {:ok, catalog} <- catalog_round_trip(),
         {:ok, browser} <- browser_round_trip(),
         {:ok, evaluation} <- evaluation_suite(),
         {:ok, notebook} <- notebook_evidence() do
      {:ok,
       %{
         browser: browser.content,
         catalog: catalog.content,
         evaluation: Enum.map(evaluation.runs, &%{case_id: &1.case_id, status: &1.status}),
         notebook_graph?: String.contains?(notebook.diagram, "flowchart"),
         operations: contract.operations,
         skill: skill.content
       }}
    end
  end

  def tool_contract do
    request =
      Turn.Request.new!(
        input: "Research Jidoka tool safety.",
        context: %{allowed_tools: ["read_page"]}
      )

    with {:ok, preflight} <- Jidoka.preflight(Agent, request) do
      operations = Enum.map(preflight.prompt.operations, & &1.name) |> Enum.sort()

      {:ok,
       %{
         operations: operations,
         expected_operations: @expected_operations,
         preflight: preflight,
         skill_metadata:
           Enum.find(Agent.spec().metadata["tool_sources"], &(&1["source"] == "skill"))
       }}
    end
  end

  def skill_round_trip(opts \\ []) do
    Jidoka.turn(Agent, "What policy governs research?",
      llm: ScriptedLLM.skill_round_trip(),
      operation_context: %{example_observer: Keyword.get(opts, :observer)}
    )
  end

  def catalog_round_trip do
    Jidoka.turn(Agent, "Find approved Jidoka sources.", llm: ScriptedLLM.catalog_round_trip())
  end

  def browser_round_trip do
    with_browser_doubles(fn ->
      Jidoka.turn(Agent, "Read the Jidoka tools guide.", llm: ScriptedLLM.browser_round_trip())
    end)
  end

  def evaluation_suite do
    definitions = [
      %{
        id: "governed_tools_required_trajectory",
        llm: ScriptedLLM.skill_round_trip()
      },
      %{
        id: "governed_tools_missing_trajectory",
        llm: ScriptedLLM.final("Use approved public sources and cite the source URL.")
      }
    ]

    runs =
      Enum.map(definitions, fn definition ->
        {:ok, run} =
          Eval.run_case(
            [
              id: definition.id,
              agent: Agent.spec(),
              input: "State the research policy.",
              assertions: %{
                contains: "approved public sources",
                operation_called: :research_policy_lookup
              },
              metadata: %{suite: "governed-tools-v1"}
            ],
            llm: definition.llm
          )

        run
      end)

    trajectory_scores =
      Map.new(runs, fn run ->
        score = if "research_policy_lookup" in run.observations.operation_calls, do: 1.0, else: 0.0
        {run.case_id, score}
      end)

    {:ok, %{runs: runs, trajectory_scores: trajectory_scores}}
  end

  def notebook_evidence do
    with {:ok, preflight} <- Jidoka.Kino.preflight(Agent, "Research Jidoka tool safety."),
         {:ok, diagram} <- Jidoka.Kino.agent_diagram(Agent) do
      {:ok, %{diagram: diagram, preflight: preflight}}
    end
  end

  defp with_browser_doubles(fun) do
    previous_actions = Application.get_env(:jidoka, :browser_actions)
    previous_resolver = Application.get_env(:jidoka, :dns_resolver)

    Application.put_env(:jidoka, :browser_actions, %{
      read_page: BrowserDoubles.ReadPage,
      search_web: BrowserDoubles.SearchWeb,
      snapshot_url: BrowserDoubles.SnapshotUrl
    })

    Application.put_env(:jidoka, :dns_resolver, fn
      ~c"docs.example.com", _family -> {:ok, [{93, 184, 216, 34}]}
      _host, _family -> {:error, :nxdomain}
    end)

    try do
      fun.()
    after
      restore_env(:browser_actions, previous_actions)
      restore_env(:dns_resolver, previous_resolver)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jidoka, key)
  defp restore_env(key, value), do: Application.put_env(:jidoka, key, value)
end
