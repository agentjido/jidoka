defmodule JidokaTest.KinoTest do
  use ExUnit.Case, async: false

  defmodule LookupAction do
    use Jidoka.Action,
      name: "lookup_contract",
      description: "Returns deterministic contract data.",
      schema:
        Zoi.object(%{
          id: Zoi.string()
        })

    @impl true
    def run(params, _context) do
      id = Map.get(params, :id) || Map.get(params, "id")
      {:ok, %{id: id, status: "active", owner: "Ada"}}
    end
  end

  defmodule Agent do
    use Jidoka.Agent

    agent :kino_test_agent do
      model %{provider: :test, id: "kino-model"}
      instructions "Use lookup_contract before answering contract questions."
    end

    tools do
      action LookupAction
    end

    controls do
      max_turns 3
    end
  end

  setup do
    env_names = Jidoka.Kino.RuntimeSetup.provider_env_names()
    original = Map.new(env_names, &{&1, System.get_env(&1)})

    Enum.each(env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(env_names, fn name ->
        case Map.fetch!(original, name) do
          nil -> System.delete_env(name)
          value -> System.put_env(name, value)
        end
      end)
    end)
  end

  test "setup_notebook mirrors Livebook secrets without requiring Kino" do
    System.put_env("LB_OPENAI_API_KEY", "test-openai-key")

    summary = Jidoka.Kino.setup_notebook(provider: :openai, model: "openai:gpt-4o-mini", render?: false)

    assert %{
             model: "openai:gpt-4o-mini",
             provider: :openai,
             live_provider?: true,
             secret_name: "LB_OPENAI_API_KEY",
             secret_source: :livebook_secret
           } = summary

    assert System.get_env("OPENAI_API_KEY") == "test-openai-key"
  end

  test "debug_agent and agent_diagram render Jidoka inspection data without Kino" do
    assert {:ok, %{kind: :agent, spec: %{id: "kino_test_agent"}}} = Jidoka.Kino.debug_agent(Agent)

    assert {:ok, markdown} = Jidoka.Kino.agent_diagram(Agent)
    assert markdown =~ "flowchart"
    assert markdown =~ "Runic turn spine"
    assert markdown =~ "lookup_contract"
  end

  test "preflight renders prompt and trace data without live effects" do
    assert {:ok, preflight} = Jidoka.Kino.preflight(Agent, "Check contract C-100.")

    assert preflight.agent.id == "kino_test_agent"
    assert Enum.map(preflight.prompt.messages, & &1.role) == [:system, :user]
    assert [%{event: :prompt_assembled}] = preflight.timeline
  end

  test "timeline and call_graph accept completed turn results" do
    assert {:ok, result} = Jidoka.turn(Agent.spec(), "Check contract C-100.", runtime_opts())

    assert {:ok, timeline} = Jidoka.Kino.timeline(result)
    assert Enum.any?(timeline, &(&1.event == :turn_finished))
    assert Enum.any?(timeline, &(Map.get(&1, :operation) == "lookup_contract"))

    assert {:ok, graph} = Jidoka.Kino.call_graph(result)
    assert graph =~ "flowchart"
    assert graph =~ "lookup_contract"
  end

  test "chat formats Jidoka turn results without requiring provider credentials" do
    assert {:ok, result} = Jidoka.turn(Agent.spec(), "Check contract C-100.", runtime_opts())

    assert {:ok, "Contract C-100 is active and owned by Ada."} =
             Jidoka.Kino.chat("deterministic turn", fn -> {:ok, result} end,
               render_trace?: false,
               render_result?: false
             )
  end

  test "context separates public and internal Jidoka keys" do
    assert :ok =
             Jidoka.Kino.context("Runtime context", %{
               "__private" => "hidden",
               tenant_id: "tenant_1",
               jidoka_spec: Agent.spec()
             })
  end

  defp fake_llm(_intent, journal, _ctx) do
    llm_calls =
      journal.results
      |> Map.values()
      |> Enum.count(&(&1.kind == :llm))

    case llm_calls do
      0 ->
        {:ok, %{type: :operation, name: "lookup_contract", arguments: %{"id" => "C-100"}}}

      1 ->
        {:ok, %{type: :final, content: "Contract C-100 is active and owned by Ada."}}
    end
  end

  defp runtime_opts do
    [
      llm: &fake_llm/3,
      operations: Jidoka.Runtime.JidoActions.operations([LookupAction])
    ]
  end
end
