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
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Review

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

    assert %{
             kind: :effect_journal,
             intent_count: 1,
             result_count: 1,
             incomplete_intents: []
           } = Jidoka.inspect(result.journal)
  end

  test "Jidoka.inspect summarizes sessions and replay data" do
    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "session inspected"}} end

    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_inspection")

    assert {:ok, %Session{} = session, _result} =
             Harness.run_session(session, [input: "Inspect session", context: %{tenant_id: "t"}],
               llm: llm
             )

    assert %{
             kind: :session,
             session_id: "sess_inspection",
             status: :finished,
             request_count: 1,
             snapshot_count: 0,
             replay: %{kind: :replay, status: :finished, timeline: timeline}
           } = Jidoka.inspect(session)

    assert Enum.any?(timeline, &(&1.event == :turn_finished))
  end

  test "Jidoka.inspect summarizes review requests" do
    interrupt =
      Review.Interrupt.new!(
        id: "intr_inspect",
        boundary: :operation,
        control: __MODULE__,
        control_name: "inspection_review",
        reason: :approval_required,
        agent_id: "inspection_agent",
        request_id: "turn_inspection",
        loop_index: 0,
        effect_id: "operation:lookup",
        effect_kind: :operation,
        operation: "lookup",
        arguments: %{"id" => "123"}
      )

    request = Review.Request.from_interrupt!(interrupt)

    assert %{
             kind: :review_request,
             interrupt_id: "intr_inspect",
             operation: "lookup",
             reason: :approval_required
           } = Jidoka.inspect(request)
  end
end
