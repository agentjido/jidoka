defmodule Jidoka.InspectionTest.Support.Agent do
  use Jidoka.Agent

  agent :inspection_agent do
    model %{provider: :test, id: "inspection-model"}
    instructions "Answer with inspection-friendly output."
    context Zoi.object(%{tenant_id: Zoi.string()})
  end
end

defmodule Jidoka.InspectionTest.Support.Workflow do
  @moduledoc false
  use Jidoka.Workflow, id: :inspection_workflow, parameters_schema: %{"type" => "object"}
  def run(_input, _context), do: {:ok, %{done: true}}
end

defmodule Jidoka.InspectionTest do
  use ExUnit.Case, async: true

  alias Jidoka.Inspection.Preflight
  alias Jidoka.Effect
  alias Jidoka.InspectionTest.Support.Agent
  alias Jidoka.InspectionTest.Support.Workflow
  alias Jidoka.Harness
  alias Jidoka.Session.Data, as: Session
  alias Jidoka.Review
  alias Jidoka.Turn

  defmodule EffectfulOperationSource do
    defstruct [:test_pid]

    def compile(%__MODULE__{test_pid: test_pid}, _opts) do
      send(test_pid, :operation_source_called)
      {:error, :must_not_run}
    end
  end

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
               phases: [:assemble_prompt, :plan_model_effect]
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

  test "preflight and execution prepare equal prompts from equal resolved inputs" do
    opts = [
      context: %{tenant_id: "tenant_1"},
      request_id: "turn_equal_preparation",
      runtime_limits: %{max_model_turns: 3},
      llm: fn _intent, _journal, _context -> {:ok, %{type: :final, content: "ok"}} end
    ]

    assert {:ok, execution} = Turn.Execution.prepare(Agent.spec(), "Prepare once", opts)
    assert {:ok, preflight} = Jidoka.preflight(Agent.spec(), "Prepare once", opts)

    assert preflight.plan == Jidoka.Projection.project(execution.prepared_turn.plan)
    assert preflight.prompt == Jidoka.Projection.project(execution.prepared_turn.state.prompt)
  end

  test "preflight reports unresolved operation discovery without calling the source" do
    source = %EffectfulOperationSource{test_pid: self()}

    assert {:error, error} =
             Jidoka.preflight(Agent, "Inspect operations",
               context: %{tenant_id: "tenant_1"},
               operation_sources: [source]
             )

    assert unresolved_cause(error) == [:unresolved_preflight_input, :operations]
    refute_receive :operation_source_called
  end

  test "preflight reports unresolved memory without calling the store" do
    spec =
      Jidoka.Agent.Spec.new!(
        id: "inspection_memory",
        model: %{provider: :test, id: "model"},
        instructions: "Use memory.",
        memory: %{enabled: true}
      )

    memory_store = fn -> send(self(), :memory_store_called) end

    assert {:error, error} =
             Jidoka.preflight(spec, "Inspect memory", memory_store: memory_store)

    assert unresolved_cause(error) == [:unresolved_preflight_input, :memory]
    refute_receive :memory_store_called
  end

  test "preflight reports unresolved instruction providers without calling them" do
    provider = fn _base, _context ->
      send(self(), :instruction_provider_called)
      "changed"
    end

    assert {:error, error} =
             Jidoka.preflight(Agent, "Inspect instructions",
               context: %{tenant_id: "tenant_1"},
               instructions: provider
             )

    assert unresolved_cause(error) == [:unresolved_preflight_input, :instructions]
    refute_receive :instruction_provider_called
  end

  test "Jidoka.inspect summarizes completed turns" do
    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "inspection ok"}} end

    assert {:ok, result} =
             Jidoka.turn(Agent.spec(), [input: "Hello", context: %{tenant_id: "tenant_1"}], llm: llm)

    assert %{
             kind: :turn,
             status: :finished,
             content: "inspection ok",
             timeline: timeline,
             journal: %{intents: [%{effect_kind: :llm}], results: [%{effect_kind: :llm, status: :ok}]}
           } = Jidoka.inspect(result)

    assert Enum.map(timeline, & &1.event) == [
             :prompt_assembled,
             :effect_planned,
             :effect_started,
             :policy_allowed,
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

  defp unresolved_cause(error) do
    error
    |> Jidoka.Error.to_map()
    |> get_in([:details, :cause, :values])
  end

  test "Jidoka.inspect summarizes sessions and replay data" do
    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "session inspected"}} end

    assert {:ok, %Session{} = session} =
             Harness.start_session(Agent.spec(), session_id: "sess_inspection")

    assert {:ok, %Session{} = session, _result} =
             Harness.run_session(session, [input: "Inspect session", context: %{tenant_id: "t"}], llm: llm)

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

  test "Jidoka.inspect suppresses effect payloads and outputs unless full output is requested" do
    intent =
      Effect.Intent.new(:operation, %{
        name: "sensitive_lookup",
        arguments: %{"api_key" => "secret-key", "tenant" => "tenant_1"}
      })

    result = Effect.Result.ok(intent, %{"token" => "secret-token", "answer" => "ok"})

    assert %{
             kind: :effect_intent,
             payload_keys: ["arguments", "loop_index", "name"]
           } = intent_view = Jidoka.inspect(intent)

    refute Map.has_key?(intent_view, :payload)

    assert %{
             kind: :effect_result,
             status: :ok
           } = result_view = Jidoka.inspect(result)

    refute Map.has_key?(result_view, :output)

    assert %{payload: %{arguments: %{"api_key" => "[REDACTED]", "tenant" => "tenant_1"}}} =
             Jidoka.inspect(intent, full?: true)

    assert %{output: %{"token" => "[REDACTED]", "answer" => "ok"}} =
             Jidoka.inspect(result, full?: true)
  end

  test "inspection covers direct workflow, plan, debug, memory, eval, and fallback views" do
    plan = Turn.Plan.new!(Agent.spec())
    assert %{kind: :plan, spec: %{id: "inspection_agent"}} = Jidoka.Inspection.inspect(plan)
    assert %{kind: :workflow, workflow: %{id: "inspection_workflow"}} = Jidoka.Inspection.inspect(Workflow)
    assert Jidoka.Inspection.inspect(:plain_value) == :plain_value

    summary = Jidoka.Debug.RequestSummary.new!(request_id: "request-1")
    diagnostics = Jidoka.Debug.ReplayDiagnostics.new!(status: :complete)
    assert %{kind: :request_debug, request_id: "request-1"} = Jidoka.Inspection.inspect(summary)
    assert %{kind: :replay_diagnostics, status: :complete} = Jidoka.Inspection.inspect(diagnostics)

    recall = struct(Jidoka.Memory.RecallResult, request: nil, entries: [], metadata: %{})
    write = struct(Jidoka.Memory.WriteResult, request: nil, entry: nil, status: :ok, metadata: %{})
    assert %{kind: :memory_recall} = Jidoka.Inspection.inspect(recall)
    assert %{kind: :memory_write} = Jidoka.Inspection.inspect(write)

    run =
      Jidoka.Eval.Run.new!(
        case_id: "case-1",
        status: :failed,
        assertions: [%{name: :answer, status: :failed}]
      )

    assert %{kind: :eval_run, failed_assertions: [%{name: :answer}]} = Jidoka.Inspection.inspect(run)
  end

  test "inspection shows invalid plans and non-map intent payloads safely" do
    %Jidoka.Agent.Spec{} = spec = Agent.spec()
    invalid_spec = %Jidoka.Agent.Spec{spec | runtime_defaults: %{phases: []}}
    assert %{kind: :agent, error: %{category: _category}} = Jidoka.Inspection.inspect(invalid_spec)

    intent =
      struct(Effect.Intent,
        id: "invalid-payload",
        kind: :llm,
        payload: :invalid,
        idempotency_key: "invalid-payload",
        idempotency: :idempotent,
        metadata: %{}
      )

    assert %{kind: :effect_intent, payload_keys: []} = Jidoka.Inspection.inspect(intent)
  end

  test "preflight accepts resolved inputs and rejects invalid resolved operations" do
    plan = Turn.Plan.new!(Agent.spec())
    request = Turn.Request.new!(input: "Inspect", context: %{tenant_id: "tenant-1"})

    assert {:ok, %Preflight{}} =
             Jidoka.Inspection.preflight(plan, request,
               resolved_operations: [],
               resolved_instructions: "Resolved instructions."
             )

    assert {:ok, %Preflight{agent: %{operations: [%{name: "lookup"}]}}} =
             Jidoka.Inspection.preflight(Agent.spec(), "Inspect",
               context: %{tenant_id: "tenant-1"},
               resolved_operations: [%{name: "lookup"}],
               instructions: "Direct instructions."
             )

    assert {:error, %Jidoka.Error.ExecutionError{}} =
             Jidoka.Inspection.preflight(Agent, "Inspect",
               context: %{tenant_id: "tenant-1"},
               resolved_operations: :invalid
             )

    assert {:error, %Jidoka.Error.ExecutionError{}} = Jidoka.Inspection.preflight(String, "Inspect")
  end

  test "preflight accepts explicit resolved memory and disabled memory" do
    %Jidoka.Agent.Spec{} =
      enabled =
      Jidoka.Agent.Spec.new!(
        id: "inspection-resolved-memory",
        instructions: "Use memory.",
        model: %{provider: :test, id: "model"},
        memory: %{enabled: true}
      )

    route = Jidoka.Memory.Route.new!(kind: :agent, agent_id: enabled.id)
    recall_request = Jidoka.Memory.RecallRequest.new!(route: route, query: "Inspect")
    memory = Jidoka.Memory.RecallResult.new!(request: recall_request, entries: [])
    assert {:ok, %Preflight{}} = Jidoka.Inspection.preflight(enabled, "Inspect", resolved_memory: memory)

    disabled = %Jidoka.Agent.Spec{enabled | memory: %{enabled.memory | enabled: false}}
    assert {:ok, %Preflight{}} = Jidoka.Inspection.preflight(disabled, "Inspect")
  end
end
