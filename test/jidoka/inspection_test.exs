defmodule Jidoka.InspectionTest.Support.Agent do
  use Jidoka.Agent

  agent :inspection_agent do
    model %{provider: :test, id: "inspection-model"}
    instructions "Answer with inspection-friendly output."
    context Zoi.object(%{tenant_id: Zoi.string()})
  end
end

defmodule Jidoka.InspectionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Inspection.Preflight
  alias Jidoka.InspectionTest.Support.Agent

  test "Jidoka.inspect returns an agent inspection view" do
    assert %{
             kind: :agent,
             module: "Jidoka.InspectionTest.Support.Agent",
             spec: %{
               id: "inspection_agent",
               model: "test:inspection-model",
               context_schema?: true
             },
             plan: %{
               spec_id: "inspection_agent",
               workflow_profile: :tool_loop
             }
           } = Jidoka.inspect(Agent)
  end

  test "Jidoka.preflight assembles the turn prompt without effects" do
    assert {:ok, %Preflight{} = preflight} =
             Jidoka.preflight(Agent, "What can you inspect?", context: %{tenant_id: "tenant_1"})

    assert %{
             model: "test:inspection-model",
             context: %{tenant_id: "tenant_1"},
             messages: [
               %{role: :system, content: "Answer with inspection-friendly output."},
               %{role: :user, content: "What can you inspect?"}
             ],
             operations: []
           } = preflight.prompt

    assert [%{event: :prompt_assembled, seq: 0}] = preflight.timeline
  end

  test "Jidoka.inspect summarizes completed turns" do
    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "inspection ok"}} end

    assert {:ok, result} =
             Jidoka.run_turn(Agent.spec(), [input: "Hello", context: %{tenant_id: "tenant_1"}],
               llm: llm
             )

    assert %{
             kind: :turn,
             status: :finished,
             content: "inspection ok",
             timeline: timeline,
             journal: %{intents: [%{kind: :llm}], results: [%{kind: :llm, status: :ok}]}
           } = Jidoka.inspect(result)

    assert Enum.map(timeline, & &1.event) == [
             :prompt_assembled,
             :effect_planned,
             :effect_started,
             :capability_call_started,
             :capability_call_completed,
             :effect_completed,
             :turn_finished
           ]
  end
end
