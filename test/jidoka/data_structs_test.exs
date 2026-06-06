defmodule Jidoka.DataStructsTest.Support.AllowControl do
  @moduledoc false

  use Jidoka.Control, name: "allow_operation"

  @impl true
  def call(_context), do: :cont
end

defmodule Jidoka.DataStructsTest.Support.AmountPredicate do
  @moduledoc false

  use Jidoka.ApprovalPredicate

  @impl true
  def call(%Jidoka.Context{arguments: arguments}) do
    (Map.get(arguments, "amount") || 0) > 100
  end
end

defmodule Jidoka.DataStructsTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Runtime.AgentSnapshot
  alias Jidoka.Turn
  alias Jidoka.DataStructsTest.Support.{AllowControl, AmountPredicate}

  test "agent state accepts nil, maps, and structs as input" do
    assert {:ok, %Agent.State{messages: [], operation_results: [], metadata: %{}}} =
             Agent.State.from_input(nil)

    assert {:ok, %Agent.State{metadata: %{"owner" => "unit"}} = state} =
             Agent.State.from_input(%{"metadata" => %{"owner" => "unit"}})

    assert {:ok, ^state} = Agent.State.from_input(state)
  end

  test "agent messages are typed durable chat data" do
    assert {:ok, %Agent.Message{role: :user, content: "hello"}} =
             Agent.Message.from_input(%{"role" => "user", "content" => "hello"})

    assert {:ok, %Agent.State{messages: [%Agent.Message{role: :assistant}]}} =
             Agent.State.from_input(%{
               "messages" => [%{"role" => "assistant", "content" => "stored"}]
             })

    assert Agent.Message.to_map(Agent.Message.tool("lookup", %{"id" => "A-1"})) == %{
             role: :tool,
             content: "%{\"id\" => \"A-1\"}",
             operation: "lookup",
             output: %{"id" => "A-1"}
           }

    assert {:error, {:missing_message_content, :assistant}} =
             Agent.Message.from_input(%{"role" => "assistant"})

    assert {:error, :missing_tool_message_operation} =
             Agent.Message.from_input(%{"role" => "tool", "content" => "missing operation"})
  end

  test "operation specs validate idempotency and normalize fields" do
    assert Operation.valid_idempotencies() == [
             :pure,
             :idempotent,
             :dedupe,
             :reconcile,
             :unsafe_once
           ]

    assert {:ok, %Operation{name: "lookup", idempotency: :pure}} =
             Operation.from_input(%{"name" => :lookup, "idempotency" => :pure})

    assert {:ok, %Operation{name: "lookup", idempotency: :pure}} =
             Operation.from_input(%{"name" => "lookup", "idempotency" => "pure"})

    assert {:error, [%Zoi.Error{path: [:idempotency]}]} =
             Operation.new(name: "lookup", idempotency: :not_valid)
  end

  test "review policies normalize approval data without creating atoms" do
    assert {:ok,
            %Review.Policy{
              required: true,
              mode: :pre_execution,
              reason: :approval_required
            }} = Review.Policy.from_input(true)

    assert {:ok,
            %Review.Policy{
              reason: "refund_review",
              message: "Review the refund.",
              ttl_ms: 30_000,
              metadata: %{"risk" => "high"}
            }} =
             Review.Policy.from_input(%{
               "reason" => "refund_review",
               "message" => "Review the refund.",
               "ttl_ms" => 30_000,
               "metadata" => %{"risk" => "high"}
             })

    assert {:ok, nil} = Review.Policy.from_input(false)
    assert {:error, {:invalid_review_policy, :bad_policy}} = Review.Policy.from_input(:bad_policy)

    assert {:ok, %Review.Policy{predicate: AmountPredicate}} =
             Review.Policy.from_input(%{"when" => AmountPredicate})

    assert {:error, {:invalid_approval_predicate, "Elixir.Missing.Predicate"}} =
             Review.Policy.from_input(%{"when" => "Elixir.Missing.Predicate"})
  end

  test "Jidoka.Context normalizes runtime context and fetches data keys safely" do
    assert {:ok,
            %Jidoka.Context{
              agent_id: "agent",
              request_id: "request",
              boundary: :operation,
              operation: "refund_order",
              operation_kind: :action,
              idempotency: :unsafe_once,
              data: %{"tenant_id" => "tenant_1", reviewer: "Ada"}
            } = context} =
             Jidoka.Context.new(%{
               "agent_id" => "agent",
               "request_id" => "request",
               "boundary" => "operation",
               "operation" => "refund_order",
               "operation_kind" => "action",
               "idempotency" => "unsafe_once",
               "context" => %{"tenant_id" => "tenant_1", reviewer: "Ada"}
             })

    assert Jidoka.Context.get(context, :tenant_id) == "tenant_1"
    assert Jidoka.Context.get(context, "reviewer") == "Ada"
    assert Jidoka.Context.get(context, :missing, :default) == :default
  end

  test "operation specs carry approval policy data" do
    assert {:ok,
            %Operation{
              approval: %Review.Policy{
                required: true,
                reason: "review_lookup",
                ttl_ms: 100
              }
            } = operation} =
             Operation.new(%{
               "name" => "lookup",
               "approval" => %{"reason" => "review_lookup", "ttl_ms" => 100}
             })

    assert Operation.approval_required?(operation)

    refute Operation.approval_required?(Operation.new!(name: "lookup_without_approval"))
  end

  test "approval source filters match operations by final operation name" do
    safe = Operation.new!(name: "safe_lookup", idempotency: :idempotent)
    unsafe = Operation.new!(name: "delete_record", idempotency: :unsafe_once)

    assert {:ok, nil} = Review.Approval.policy_for_operation(:unsafe_once, safe)
    assert {:ok, %Review.Policy{}} = Review.Approval.policy_for_operation(:unsafe_once, unsafe)

    assert {:ok, %Review.Policy{reason: "review_delete"}} =
             Review.Approval.policy_for_operation(
               [only: ["delete_record"], reason: "review_delete"],
               unsafe
             )

    assert {:ok, nil} =
             Review.Approval.policy_for_operation(
               [except: [:delete_record], reason: "review_all"],
               unsafe
             )

    assert {:ok, %Review.Policy{}} =
             Review.Approval.policy_for_operation(
               :unsafe_once,
               %{"name" => :delete_record, "idempotency" => "unsafe_once"}
             )
  end

  test "operation policies expose replay and control semantics" do
    assert Operation.kind(Operation.new!(name: "lookup")) == :operation

    assert Operation.kind(Operation.new!(name: "lookup", metadata: %{"runtime" => "jido_action"})) ==
             :action

    assert Operation.kind(Operation.new!(name: "lookup", metadata: %{kind: "workflow"})) ==
             :workflow

    assert Operation.kind(Operation.new!(name: "lookup", metadata: %{kind: "browser"})) ==
             :browser

    assert Operation.kind(Operation.new!(name: "lookup", metadata: %{"kind" => "ash_resource"})) ==
             :ash_resource

    assert Operation.requires_control?(:unsafe_once)
    refute Operation.requires_control?(:idempotent)

    refute Operation.replay_safe?(:unsafe_once)
    assert Operation.replay_safe?(:dedupe)
  end

  test "unsafe once operations require explicit operation controls before planning" do
    unsafe_operation =
      Operation.new!(
        name: "charge_card",
        description: "Charges a customer card.",
        idempotency: :unsafe_once
      )

    spec =
      Agent.Spec.new!(
        id: "unsafe_without_control",
        instructions: "Charge only when explicitly requested.",
        operations: [unsafe_operation]
      )

    assert {:error, {:unsafe_once_requires_control, "charge_card", :operation}} =
             Agent.Spec.validate_operation_policies(spec)

    assert {:error, {:unsafe_once_requires_control, "charge_card", :operation}} =
             Turn.Plan.new(spec)

    approved_spec =
      Agent.Spec.new!(
        id: "unsafe_with_approval_policy",
        instructions: "Charge only when explicitly requested.",
        operations: [
          Operation.new!(
            name: "charge_card",
            description: "Charges a customer card.",
            idempotency: :unsafe_once,
            approval: true
          )
        ]
      )

    assert :ok = Agent.Spec.validate_operation_policies(approved_spec)
    assert {:ok, %Turn.Plan{}} = Turn.Plan.new(approved_spec)

    controlled_spec =
      Agent.Spec.new!(
        id: "unsafe_with_control",
        instructions: "Charge only when explicitly requested.",
        operations: [unsafe_operation],
        controls:
          Controls.new!(
            operations: [
              %{control: AllowControl, match: %{name: "charge_card"}}
            ]
          )
      )

    assert :ok = Agent.Spec.validate_operation_policies(controlled_spec)
    assert {:ok, %Turn.Plan{}} = Turn.Plan.new(controlled_spec)
  end

  test "operation controls can match by source, idempotency, and metadata" do
    operation =
      Operation.new!(
        name: "charge_card",
        idempotency: :unsafe_once,
        metadata: %{
          "source" => "payments",
          "kind" => "tool",
          "risk" => "high",
          mode: :live
        }
      )

    matching =
      Controls.Operation.new!(
        control: AllowControl,
        match: %{
          source: :payments,
          idempotency: "unsafe_once",
          metadata: %{"risk" => "high", "mode" => "live"}
        }
      )

    non_matching =
      Controls.Operation.new!(
        control: AllowControl,
        match: %{source: :browser}
      )

    assert Controls.Operation.matches?(matching, operation)
    refute Controls.Operation.matches?(non_matching, operation)
  end

  test "control specs accept output controls as the public data key" do
    assert %Controls{outputs: [%Controls.Output{control: AllowControl}]} =
             Controls.new!(
               outputs: [
                 %{control: AllowControl}
               ]
             )
  end

  test "structured result specs require Zoi schemas and normalize JSON-style keys" do
    assert {:error, {:invalid_result_schema, :not_a_schema}} =
             Agent.Spec.Result.new(schema: :not_a_schema)

    assert_raise ArgumentError, ~r/invalid_result_schema/, fn ->
      Agent.Spec.Result.new!(schema: :not_a_schema)
    end

    assert {:ok, %Agent.Spec.Result{} = result} =
             Agent.Spec.Result.new(
               schema:
                 Zoi.object(%{
                   answer: Zoi.string(),
                   citations:
                     Zoi.array(
                       Zoi.object(%{
                         url: Zoi.string()
                       })
                     )
                 })
             )

    assert {:ok, %{answer: "Ada", citations: [%{url: "https://example.com"}]}} =
             Agent.Spec.Result.validate(result, %{
               "answer" => "Ada",
               "citations" => [%{"url" => "https://example.com"}]
             })
  end

  test "effect intents derive stable ids and results preserve status" do
    first = Effect.Intent.new(:llm, %{request_id: "turn_1", loop_index: 0})
    second = Effect.Intent.new(:llm, %{request_id: "turn_1", loop_index: 0})
    custom = Effect.Intent.new(:operation, %{name: "lookup"}, id: "custom", idempotency_key: "k")

    assert first.id == second.id
    assert first.idempotency_key == second.idempotency_key
    assert custom.id == "custom"

    assert %Effect.Result{kind: :llm, status: :ok, output: %{ok: true}} =
             Effect.Result.ok(first, %{ok: true})

    assert %Effect.Result{kind: :operation, status: :error, output: :failed} =
             Effect.Result.error(custom, :failed)
  end

  test "effect contracts accept decoded string enums without creating atoms" do
    assert {:ok, %Effect.Intent{kind: :operation, idempotency: :dedupe}} =
             Effect.Intent.new(%{
               "id" => "operation:1",
               "kind" => "operation",
               "payload" => %{"name" => "lookup"},
               "idempotency_key" => "key-1",
               "idempotency" => "dedupe"
             })

    assert {:error, _reason} =
             Effect.Intent.new(%{
               id: "operation:bad",
               kind: :operation,
               payload: %{},
               idempotency_key: "bad"
             })

    assert {:ok, %Effect.Result{kind: :operation, status: :ok}} =
             Effect.Result.new(%{
               "intent_id" => "operation:1",
               "kind" => "operation",
               "status" => "ok",
               "output" => %{"value" => 1}
             })

    assert {:ok, %Turn.Cursor{phase: :before_effect}} =
             Turn.Cursor.new(%{"phase" => "before_effect"})
  end

  test "LLM decisions and operation observations are typed effect payloads" do
    assert {:ok, %Effect.LLMDecision{type: :operation, name: "lookup"}} =
             Effect.LLMDecision.from_input(%{
               "type" => "operation",
               "name" => "lookup",
               "arguments" => %{"id" => "A-1"}
             })

    intent =
      Effect.Intent.new(:operation, %{
        name: "lookup",
        arguments: %{"id" => "A-1"},
        request_id: "turn_1",
        loop_index: 0
      })

    assert {:ok,
            %Effect.OperationResult{
              operation: "lookup",
              arguments: %{"id" => "A-1"},
              output: %{"name" => "Ada"},
              effect_id: effect_id
            }} = Effect.OperationResult.from_effect(intent, %{"name" => "Ada"})

    assert effect_id == intent.id
  end

  test "effect journals keep intents and replace results by intent id" do
    intent = Effect.Intent.new(:llm, %{request_id: "turn_1"})
    first = Effect.Result.ok(intent, %{type: :final, content: "first"})
    second = Effect.Result.ok(intent, %{type: :final, content: "second"})

    journal =
      Effect.Journal.new!()
      |> Effect.Journal.put_intent(intent)
      |> Effect.Journal.put_result(first)
      |> Effect.Journal.put_result(second)

    assert journal.intents[intent.id] == intent
    assert Effect.Journal.result_for(journal, intent) == second
  end

  test "turn requests normalize string input and preserve supplied state" do
    assert {:ok, %Turn.Request{} = request} = Turn.Request.from_input("Hello")
    assert request.input == "Hello"
    assert request.request_id =~ "turn_"
    assert %Agent.State{} = request.agent_state

    agent_state = Agent.State.new!(messages: [%{role: :user, content: "prior"}])

    assert {:ok, %Turn.Request{agent_state: ^agent_state, context: %{tenant: "t1"}}} =
             Turn.Request.from_input(
               input: "Hello",
               agent_state: agent_state,
               context: %{tenant: "t1"}
             )
  end

  test "turn request id generation can be injected" do
    generator = fn "turn" -> "turn_test_1" end

    assert {:ok, %Turn.Request{request_id: "turn_test_1"}} =
             Turn.Request.from_input("Hello", id_generator: generator)

    assert {:error, {:invalid_generated_id, "turn", nil}} =
             Turn.Request.from_input("Hello", id_generator: fn "turn" -> nil end)

    assert {:error, {:id_generator_failed, "turn", {:exception, %RuntimeError{}}}} =
             Turn.Request.from_input("Hello", id_generator: fn "turn" -> raise "boom" end)
  end

  test "turn cursors describe checkpoint positions" do
    intent = Effect.Intent.new(:operation, %{name: "lookup"})
    interrupt = interrupt()

    assert %Turn.Cursor{phase: :after_prompt, loop_index: 0} = Turn.Cursor.after_prompt()

    assert %Turn.Cursor{phase: :before_effect, metadata: metadata} =
             Turn.Cursor.before_effect(intent)

    assert metadata["effect_id"] == intent.id
    assert metadata["effect_kind"] == :operation

    assert %Turn.Cursor{phase: :review, metadata: review_metadata} = Turn.Cursor.review(interrupt)
    assert review_metadata["interrupt_id"] == interrupt.id
    assert review_metadata["operation"] == "lookup"
  end

  test "interrupt and approval contracts are serializable data" do
    interrupt = interrupt()

    assert Review.Interrupt.expired?(interrupt, 1_001) == false

    interrupt = Review.Interrupt.with_review_window(interrupt, 1_000, 10)
    assert interrupt.created_at_ms == 1_000
    assert interrupt.expires_at_ms == 1_010
    assert Review.Interrupt.expired?(interrupt, 1_011)

    assert %Review.Request{
             interrupt_id: interrupt_id,
             operation: "lookup",
             arguments: %{"id" => "A-1"}
           } = Review.Request.from_interrupt!(interrupt)

    assert interrupt_id == interrupt.id

    assert %Review.Response{interrupt_id: ^interrupt_id, decision: :approved} =
             Review.Response.approve(interrupt)

    assert %Review.Response{interrupt_id: ^interrupt_id, decision: :denied, reason: :rejected} =
             Review.Response.deny(interrupt.id, reason: :rejected)
  end

  test "agent snapshots round-trip from serializable maps" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert snapshot.schema_version == AgentSnapshot.schema_version()

    assert {:ok, %AgentSnapshot{} = restored} =
             snapshot
             |> portable_map()
             |> AgentSnapshot.from_input()

    assert restored.schema_version == AgentSnapshot.schema_version()
    assert restored.agent_id == "snapshot_agent"
    assert restored.cursor.phase == :after_prompt
    assert restored.turn_state.spec.id == "snapshot_agent"
  end

  test "agent snapshot id generation can be explicit or injected" do
    state = base_state()

    assert {:ok, %AgentSnapshot{snapshot_id: "snap_explicit"}} =
             AgentSnapshot.from_turn_state(state, Turn.Cursor.after_prompt(), snapshot_id: "snap_explicit")

    assert {:ok, %AgentSnapshot{snapshot_id: "snap_injected"}} =
             AgentSnapshot.from_turn_state(state, Turn.Cursor.after_prompt(),
               id_generator: fn "snap" -> "snap_injected" end
             )
  end

  test "agent snapshots serialize and deserialize through the hibernate contract" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert {:ok, serialized} = AgentSnapshot.serialize(snapshot)
    assert serialized =~ "jidoka:snapshot:v1:"

    assert {:ok, %AgentSnapshot{} = restored} = AgentSnapshot.deserialize(serialized)
    assert restored.snapshot_id == snapshot.snapshot_id
    assert restored.cursor.phase == :after_prompt
    assert restored.turn_state.spec.id == "snapshot_agent"
  end

  test "snapshot serialization rejects non-portable runtime values" do
    state = base_state()
    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{callback: fn -> :ok end}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :callback], :function}} =
             AgentSnapshot.serialize(snapshot)

    snapshot = AgentSnapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{wrapped: {:ok, fn -> :ok end}}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :wrapped, 1], :function}} =
             AgentSnapshot.serialize(snapshot)
  end

  test "turn results require a finished state" do
    %Turn.State{} = state = base_state()
    finished = %{state | status: :finished, result: "done"}

    assert %Turn.Result{content: "done"} = Turn.Result.from_turn_state!(finished)

    assert_raise FunctionClauseError, fn ->
      Turn.Result.from_turn_state!(state)
    end
  end

  defp base_state do
    spec =
      Agent.Spec.new!(
        id: "snapshot_agent",
        instructions: "Snapshot test.",
        model: %{provider: :test, id: "model"}
      )

    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(input: "Hello")

    Turn.State.new!(
      spec: spec,
      plan: plan,
      request: request,
      agent_state: request.agent_state
    )
  end

  defp interrupt do
    Review.Interrupt.new!(
      id: Review.Interrupt.stable_id(["test", "lookup"]),
      boundary: :operation,
      control: __MODULE__,
      control_name: "test_control",
      reason: :approval_required,
      agent_id: "snapshot_agent",
      request_id: "turn_1",
      loop_index: 0,
      effect_id: "operation:lookup",
      effect_kind: :operation,
      operation: "lookup",
      operation_kind: :operation,
      arguments: %{"id" => "A-1"},
      idempotency: :idempotent,
      idempotency_key: "key"
    )
  end

  defp portable_map(%_{} = value), do: value |> Map.from_struct() |> portable_map()

  defp portable_map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), portable_map(nested)} end)
  end

  defp portable_map(value) when is_list(value), do: Enum.map(value, &portable_map/1)
  defp portable_map(value), do: value
end
