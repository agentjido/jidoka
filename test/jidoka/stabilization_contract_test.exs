defmodule Jidoka.StabilizationContractTest.Support.AllowControl do
  @moduledoc false

  use Jidoka.Control, name: "stabilization_allow"

  @impl true
  def call(_context), do: :cont
end

defmodule Jidoka.StabilizationContractTest.Support.WorkflowOk do
  @moduledoc false

  use Jidoka.Workflow,
    id: :contract_workflow,
    description: "Runs a deterministic contract workflow.",
    parameters_schema: %{"type" => "object"}

  @impl true
  def run(input, context), do: {:ok, %{input: input, context: context}}
end

defmodule Jidoka.StabilizationContractTest.Support.WorkflowValue do
  @moduledoc false

  use Jidoka.Workflow, id: "value_workflow"

  @impl true
  def run(input, _context), do: %{accepted: input}
end

defmodule Jidoka.StabilizationContractTest.Support.WorkflowRaises do
  @moduledoc false

  use Jidoka.Workflow, id: "raising_workflow"

  @impl true
  def run(_input, _context), do: raise("workflow failed")
end

defmodule Jidoka.StabilizationContractTest.Support.WorkflowThrows do
  @moduledoc false

  use Jidoka.Workflow, id: "throwing_workflow"

  @impl true
  def run(_input, _context), do: throw(:workflow_threw)
end

defmodule Jidoka.StabilizationContractTest.Support.MissingRunWorkflow do
  @moduledoc false

  def id, do: "missing_run_workflow"
end

defmodule Jidoka.StabilizationContractTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Handoff
  alias Jidoka.Harness
  alias Jidoka.Harness.Session
  alias Jidoka.Id
  alias Jidoka.Inspection.Preflight
  alias Jidoka.Memory
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Runtime.Controls.OperationContext
  alias Jidoka.Runtime.ReqLLM
  alias Jidoka.Schema
  alias Jidoka.Turn
  alias Jidoka.StabilizationContractTest.Support

  test "root facade exposes the locked API and omits legacy orchestration helpers" do
    Code.ensure_loaded!(Jidoka)

    expected_exports = [
      agent: 1,
      agent!: 1,
      import: 1,
      import: 2,
      export: 1,
      export: 2,
      start_agent: 1,
      start_agent: 2,
      stop_agent: 1,
      stop_agent: 2,
      whereis: 1,
      whereis: 2,
      session: 1,
      session: 2,
      session: 3,
      handoff: 1,
      reset_handoff: 1,
      plan: 1,
      plan!: 1,
      chat: 2,
      chat: 3,
      chat_async: 2,
      chat_async: 3,
      stream: 1,
      stream: 2,
      await: 1,
      await: 2,
      turn: 2,
      turn: 3,
      await_agent: 1,
      await_agent: 2,
      resume: 1,
      resume: 2,
      format_error: 1,
      error_to_map: 1,
      inspect: 1,
      inspect: 2,
      preflight: 2,
      preflight: 3,
      project: 1,
      normalize_error: 1,
      normalize_error: 2
    ]

    for {function, arity} <- expected_exports do
      assert function_exported?(Jidoka, function, arity),
             "expected Jidoka.#{function}/#{arity} to remain public"
    end

    removed_v1_exports = [
      model_aliases: 0,
      model: 1,
      import_agent: 1,
      import_agent_file: 1,
      encode_agent: 1,
      chat_stream: 3,
      start_chat_request: 3,
      await_chat_request: 2,
      schedule_agent: 3,
      inspect_agent: 1,
      prompt_preflight: 2,
      new_agent: 1,
      compile_turn_plan!: 1,
      handoff_owner: 1,
      run_turn: 2,
      run_turn: 3,
      projection: 1
    ]

    for {function, arity} <- removed_v1_exports do
      refute function_exported?(Jidoka, function, arity),
             "Legacy helper Jidoka.#{function}/#{arity} should not be part of the locked API"
    end
  end

  test "enum parsing rejects unknown strings without creating atoms" do
    before_count = :erlang.system_info(:atom_count)

    for index <- 1..20 do
      value = "jidoka_unknown_enum_#{System.unique_integer([:positive])}_#{index}"
      assert {:error, _reason} = Schema.parse_atom_enum(value, [:ok, :error], [])
    end

    assert :erlang.system_info(:atom_count) == before_count
  end

  test "id generation keeps entropy and injected generator failures at the boundary" do
    assert {:ok, "turn_" <> random} = Id.generate("turn")
    assert byte_size(random) > 0

    assert {:ok, "turn_static"} = Id.generate("turn", fn "turn" -> "turn_static" end)

    assert {:error, {:invalid_id_generator, "turn", :bad_generator}} =
             Id.generate("turn", :bad_generator)

    assert {:error, {:id_generator_failed, "turn", {:throw, :bad_id}}} =
             Id.generate("turn", fn _prefix -> throw(:bad_id) end)

    assert_raise ArgumentError, ~r/invalid generated id/, fn ->
      Id.generate!("turn", fn _prefix -> "" end)
    end
  end

  test "preflight and operation control context are explicit data contracts" do
    assert {:ok, %Preflight{agent: %{"id" => "agent"}, diagnostics: []}} =
             Preflight.new(
               agent: %{"id" => "agent"},
               plan: %{},
               request: %{},
               prompt: %{"messages" => []}
             )

    assert_raise ArgumentError, ~r/invalid inspection preflight/, fn ->
      Preflight.new!(agent: %{})
    end

    assert {:ok,
            %OperationContext{
              type: :control,
              boundary: :operation,
              control: Support.AllowControl,
              kind: :action,
              operation_kind: :action,
              operation: "refund_order",
              idempotency: :unsafe_once
            }} =
             OperationContext.new(%{
               "control" => Support.AllowControl,
               "control_name" => "stabilization_allow",
               "operation" => "refund_order",
               "kind" => "action",
               "operation_kind" => "action",
               "input" => "Refund order_123",
               "idempotency" => "unsafe_once",
               "spec" => %{},
               "plan" => %{},
               "request" => %{},
               "agent_state" => %{},
               "intent" => %{},
               "operation_request" => %{}
             })
  end

  test "handoffs and sessions enforce versioned durable data" do
    attrs = %{
      conversation_id: "conv_1",
      from_agent: "support_agent",
      to_agent: Support.WorkflowOk,
      to_agent_id: "contract_workflow",
      name: "contract_workflow",
      message: "Please take ownership.",
      summary: "Needs specialist review.",
      reason: "specialist_needed",
      context: %{"order_id" => "A1001"}
    }

    assert {:ok, %Handoff{id: "handoff_static", conversation_id: "conv_1"} = handoff} =
             Handoff.new(attrs, id_generator: fn "handoff" -> "handoff_static" end)

    assert {:ok, ^handoff} = Handoff.from_input(handoff)

    assert {:error, {:invalid_generated_id, "handoff", ""}} =
             Handoff.new(attrs, id_generator: fn "handoff" -> "" end)

    spec = agent_spec()

    assert Session.statuses() == [:new, :running, :hibernated, :waiting, :finished, :error]

    assert {:error, {:unsupported_session_schema_version, 2, 1}} =
             Session.new(%{
               schema_version: 2,
               session_id: "sess_future",
               agent_id: spec.id,
               spec: spec
             })

    assert {:error, {:invalid_session_id, ""}} = Session.start(spec, session_id: "")
  end

  test "session transitions clear stale errors and project review snapshots" do
    spec = agent_spec()
    {:ok, session} = Session.start(spec, session_id: "sess_contract")
    request = Turn.Request.new!(input: "Hello")

    session =
      session
      |> Session.put_error(:failed)
      |> Session.put_request(request)

    assert session.status == :running
    assert session.error == nil
    assert [^request] = session.requests

    interrupt = review_interrupt(spec, request)
    state = base_state(spec, request) |> Turn.State.put_pending_interrupt(interrupt)
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.review(interrupt))

    session = Session.put_snapshot(session, snapshot)

    assert session.status == :waiting
    assert [%Review.Request{operation: "refund_order"}] = session.pending_reviews

    finished = %{state | status: :finished, result: "done"}
    result = Turn.Result.from_turn_state!(finished)

    session =
      session
      |> Session.put_error(:stale)
      |> Session.put_result(result)

    assert session.status == :finished
    assert session.error == nil
    assert session.pending_reviews == []
  end

  test "snapshots reject invalid serialized payloads and future schema versions" do
    spec = agent_spec()
    request = Turn.Request.new!(input: "Hello")

    snapshot =
      AgentSnapshot.from_turn_state!(base_state(spec, request), Turn.Cursor.after_prompt())

    assert {:error, :invalid_snapshot_serialization} = AgentSnapshot.deserialize("not-a-snapshot")

    assert {:error, {:invalid_snapshot_serialization, _error}} =
             AgentSnapshot.deserialize("jidoka:snapshot:v1:not-valid-base64")

    future = %{snapshot | schema_version: AgentSnapshot.schema_version() + 1}

    encoded =
      future
      |> :erlang.term_to_binary()
      |> Base.url_encode64(padding: false)

    assert {:error, {:unsupported_snapshot_schema_version, 2, 1}} =
             AgentSnapshot.deserialize("jidoka:snapshot:v1:" <> encoded)
  end

  test "inspection views cover the locked runtime data contracts" do
    spec = agent_spec()
    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")
    %Turn.State{} = state = base_state(spec, request)
    intent = Effect.Intent.new(:llm, %{request_id: request.request_id, prompt: %{messages: []}})
    effect_result = Effect.Result.ok(intent, %{type: :final, content: "done"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)
      |> Effect.Journal.put_result(effect_result)

    finished_state = %Turn.State{state | status: :finished, result: "done", journal: journal}
    turn_result = Turn.Result.from_turn_state!(finished_state)
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    session =
      Session.start(spec, session_id: "sess_inspect") |> elem(1) |> Session.put_snapshot(snapshot)

    {:ok, replay} = Harness.replay(session)
    interrupt = review_interrupt(spec, request)
    review_request = Review.Request.from_interrupt!(interrupt)
    review_response = Review.Response.approve(interrupt)

    entry =
      Memory.Entry.new!(
        agent_id: spec.id,
        session_id: "sess_inspect",
        content: "Ada prefers concise answers.",
        id: "mem_1"
      )

    recall_request =
      Memory.RecallRequest.new!(
        agent_id: spec.id,
        session_id: "sess_inspect",
        scope: :session,
        query: "Ada",
        limit: 1
      )

    recall_result = Memory.RecallResult.new!(request: recall_request, entries: [entry])
    write_request = Memory.WriteRequest.new!(entry: entry)
    write_result = Memory.WriteResult.new!(request: write_request, entry: entry)

    eval_run =
      Jidoka.Eval.Run.new!(
        case_id: "eval_inspect",
        status: :failed,
        result: turn_result,
        assertions: [%{name: :contains, status: :failed, expected: "ok", actual: "done"}],
        observations: %{content: "done"}
      )

    assert %{kind: :agent, spec: %{id: spec_id}} = Jidoka.inspect(spec)
    assert spec_id == spec.id
    assert %{kind: :plan, plan: %{spec_id: ^spec_id}} = Jidoka.inspect(plan)
    assert %{kind: :turn, status: :finished, content: "done"} = Jidoka.inspect(turn_result)
    assert %{kind: :turn_state, status: :running} = Jidoka.inspect(state)
    assert %{kind: :snapshot, cursor: %{phase: :after_prompt}} = Jidoka.inspect(snapshot)

    assert %{kind: :session, session_id: "sess_inspect", snapshot_count: 1} =
             Jidoka.inspect(session)

    assert %{kind: :replay, session_id: "sess_inspect", snapshot_count: 1} =
             Jidoka.inspect(replay)

    assert %{
             kind: :effect_journal,
             intent_count: 1,
             result_count: 1,
             incomplete_intents: []
           } = Jidoka.inspect(journal)

    assert %{kind: :effect_intent, effect_id: effect_id} = Jidoka.inspect(intent)
    assert effect_id == intent.id
    assert %{kind: :effect_result, intent_id: ^effect_id} = Jidoka.inspect(effect_result)
    assert %{kind: :review_interrupt, operation: "refund_order"} = Jidoka.inspect(interrupt)
    assert %{kind: :review_request, operation: "refund_order"} = Jidoka.inspect(review_request)
    assert %{kind: :review_response, decision: :approved} = Jidoka.inspect(review_response)
    assert %{kind: :memory_recall, entries: [%{id: "mem_1"}]} = Jidoka.inspect(recall_result)
    assert %{kind: :memory_write, entry: %{id: "mem_1"}} = Jidoka.inspect(write_result)
    assert %{kind: :eval_run, status: :failed, failed_assertions: [_]} = Jidoka.inspect(eval_run)
    assert :not_a_jidoka_agent == Jidoka.inspect(:not_a_jidoka_agent)
  end

  test "workflow contracts normalize definitions, run values, and contain failures" do
    assert {:ok,
            %{
              id: "contract_workflow",
              module: Support.WorkflowOk,
              description: "Runs a deterministic contract workflow.",
              parameters_schema: %{"type" => "object"}
            }} = Jidoka.Workflow.definition(Support.WorkflowOk)

    assert {:ok, %{input: %{value: "A"}, context: %{tenant: "northwind"}}} =
             Jidoka.Workflow.run(Support.WorkflowOk, [value: "A"], context: %{tenant: "northwind"})

    assert {:ok, %{accepted: %{value: "B"}}} =
             Jidoka.Workflow.run(Support.WorkflowValue, %{value: "B"})

    assert {:error, %RuntimeError{message: "workflow failed"}} =
             Jidoka.Workflow.run(Support.WorkflowRaises, %{})

    assert {:error, {:throw, :workflow_threw}} = Jidoka.Workflow.run(Support.WorkflowThrows, %{})

    assert {:error, {:invalid_workflow_module, Support.MissingRunWorkflow, :missing_run}} =
             Jidoka.Workflow.definition(Support.MissingRunWorkflow)

    assert {:error, {:invalid_workflow_id, "Bad ID"}} = Jidoka.Workflow.normalize_id("Bad ID")

    assert_raise ArgumentError, ~r/invalid workflow id/, fn ->
      Jidoka.Workflow.normalize_id!("Bad ID")
    end
  end

  test "ReqLLM effect boundary rejects malformed payloads before provider calls" do
    journal = Effect.Journal.new!()
    operation_intent = Effect.Intent.new(:operation, %{name: "lookup"})

    assert {:error, {:unsupported_effect_kind, :operation}} =
             ReqLLM.generate(operation_intent, journal, [])

    missing_prompt = Effect.Intent.new(:llm, %{request_id: "turn_1"})

    assert {:error, {:missing_prompt_payload, %{request_id: "turn_1"}}} =
             ReqLLM.generate(missing_prompt, journal, model: %{provider: :test, id: "model"})

    invalid_prompt = Effect.Intent.new(:llm, %{prompt: "bad"})

    assert {:error, {:invalid_prompt_payload, "bad"}} =
             ReqLLM.generate(invalid_prompt, journal, model: %{provider: :test, id: "model"})

    llm = ReqLLM.llm(model: %{provider: :test, id: "model"})
    assert is_function(llm, 2)
    assert {:error, {:unsupported_effect_kind, :operation}} = llm.(operation_intent, journal)
  end

  defp agent_spec do
    Agent.Spec.new!(
      id: "stabilization_contract_agent",
      instructions: "Exercise stable data contracts.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp base_state(spec, request) do
    Turn.State.new!(
      spec: spec,
      plan: Turn.Plan.new!(spec),
      request: request,
      agent_state: request.agent_state
    )
  end

  defp review_interrupt(spec, request) do
    Review.Interrupt.new!(
      id: Review.Interrupt.stable_id([spec.id, request.request_id, "refund_order"]),
      boundary: :operation,
      control: Support.AllowControl,
      control_name: "stabilization_allow",
      reason: :approval_required,
      agent_id: spec.id,
      request_id: request.request_id,
      loop_index: 0,
      effect_id: "operation:refund_order",
      effect_kind: :operation,
      operation: "refund_order",
      operation_kind: :action,
      arguments: %{"order_id" => "A1001"},
      idempotency: :unsafe_once,
      idempotency_key: "key"
    )
  end
end
