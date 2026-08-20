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

defmodule Jidoka.DataStructsTest.Support.CallerData do
  @moduledoc false

  defstruct [:actor, :tenant]
end

defmodule Jidoka.DataStructsTest.Support.PredicateResults do
  @moduledoc false

  use Jidoka.ApprovalPredicate

  def call(%Jidoka.Context{data: %{result: result}}) do
    case result do
      :raise -> raise "predicate failed"
      :throw -> throw(:predicate_failed)
      result -> result
    end
  end
end

defmodule Jidoka.DataStructsTest do
  use ExUnit.Case, async: true

  @turn_uuid7_regex ~r/\Aturn_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  alias Jidoka.Agent
  alias Jidoka.Agent.Spec.Controls
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Review
  alias Jidoka.Snapshot
  alias Jidoka.Turn
  alias Jidoka.DataStructsTest.Support.{AllowControl, AmountPredicate, CallerData}
  alias Jidoka.DataStructsTest.Support.PredicateResults

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

    assert {:error, {:invalid_message_role_fields, :user, [:output]}} =
             Agent.Message.from_input(%{role: :user, content: "hello", output: %{unexpected: true}})

    assert {:error, _reason} =
             Agent.State.from_input(%{
               messages: [%{role: :assistant, content: "hello", operation: "not-an-assistant-field"}]
             })

    direct = Agent.Message.user("direct")
    assert {:ok, ^direct} = Agent.Message.from_input(direct)

    for message <- [
          Agent.Message.system("system"),
          Agent.Message.user("user"),
          Agent.Message.assistant("assistant"),
          Agent.Message.tool("lookup", %{ok: true})
        ] do
      assert {:ok, ^message} = Agent.Message.from_input(message)
    end
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

  test "approval predicates validate modules and normalize every result shape" do
    assert :ok = Jidoka.ApprovalPredicate.validate_module(nil)
    assert :ok = Jidoka.ApprovalPredicate.validate_module(PredicateResults)

    assert {:error, {:invalid_approval_predicate_module, String}} =
             Jidoka.ApprovalPredicate.validate_module(String)

    assert {:error, {:approval_predicate_not_loaded, MissingPredicate, _reason}} =
             Jidoka.ApprovalPredicate.validate_module(MissingPredicate)

    assert {:error, {:invalid_approval_predicate, "invalid"}} =
             Jidoka.ApprovalPredicate.validate_module("invalid")

    assert {:ok, true} =
             Jidoka.ApprovalPredicate.evaluate(nil, Jidoka.Context.from_data!(%{}))

    for {result, expected} <- [
          {true, {:ok, true}},
          {{:ok, false}, {:ok, false}},
          {{:error, :denied}, {:error, :denied}},
          {:invalid, {:error, {:invalid_approval_predicate_result, PredicateResults, :invalid}}}
        ] do
      assert Jidoka.ApprovalPredicate.evaluate(
               PredicateResults,
               Jidoka.Context.from_data!(%{result: result})
             ) == expected
    end

    assert {:error, {:approval_predicate_failed, PredicateResults, %RuntimeError{}}} =
             Jidoka.ApprovalPredicate.evaluate(
               PredicateResults,
               Jidoka.Context.from_data!(%{result: :raise})
             )

    assert {:error, {:approval_predicate_failed, PredicateResults, {:throw, :predicate_failed}}} =
             Jidoka.ApprovalPredicate.evaluate(
               PredicateResults,
               Jidoka.Context.from_data!(%{result: :throw})
             )

    assert {:error, {:invalid_approval_predicate, "invalid"}} =
             Jidoka.ApprovalPredicate.evaluate(
               "invalid",
               Jidoka.Context.from_data!(%{})
             )
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

    assert %Jidoka.Context{data: %{tenant: "northwind"}, runtime: %{client: :trusted}} =
             Jidoka.Context.from_data!(%{tenant: "northwind"}, runtime: %{client: :trusted})

    trusted_context =
      Jidoka.Context.from_data!(%{tenant: "northwind"},
        runtime: %{client: :trusted},
        boundary: :operation,
        operation: "refund_order"
      )

    assert %Jidoka.Context{
             data: %{tenant: "northwind"},
             runtime: %{},
             boundary: nil,
             operation: nil
           } = Jidoka.Context.from_data!(trusted_context)

    assert %Jidoka.Context{runtime: %{client: :trusted}} =
             Jidoka.Context.from_data!(trusted_context, runtime: %{client: :trusted})

    assert %Jidoka.Context{data: %{}} = Jidoka.Context.from_data!(nil)
    assert {:error, {:invalid_context_data, :invalid}} = Jidoka.Context.from_data(:invalid)

    assert_raise ArgumentError, ~r/invalid context data/, fn ->
      Jidoka.Context.from_data!(:invalid)
    end

    assert %{tenant: "northwind"} =
             Jidoka.Context.from_data!(%{tenant: "northwind"}, runtime: %{client: :trusted})
             |> Jidoka.Context.sanitize()
             |> Jidoka.Context.data()
  end

  test "Jidoka.Context projects a spoof-safe Jido action context" do
    context =
      Jidoka.Context.from_data!(
        %{
          "__jidoka__" => :spoofed_string,
          actor: "actor-1",
          tenant: "tenant-1",
          __jidoka__: :spoofed_atom
        },
        runtime: %{client: :trusted},
        boundary: :operation,
        operation: "lookup"
      )

    action_context = Jidoka.Context.to_action_context(context)

    refute is_struct(action_context)
    assert Map.get(action_context, :actor) == "actor-1"
    assert action_context[:tenant] == "tenant-1"
    assert Jidoka.Context.get(action_context, :actor) == "actor-1"
    assert Jidoka.Context.get_runtime(action_context, :client) == :trusted
    assert Jidoka.Context.fetch_runtime(%{}, :client) == :error
    assert Jidoka.Context.get_runtime(%{}, :client, :missing) == :missing
    assert action_context.__jidoka__.context == context
    refute Map.has_key?(action_context, "__jidoka__")
    refute Map.has_key?(action_context, :runtime)
    refute Map.has_key?(action_context, :operation)
  end

  test "Jidoka.Context removes struct identity from Jido action context data" do
    %Jidoka.Context{} = context = Jidoka.Context.from_data!(%{})

    context =
      %Jidoka.Context{
        context
        | data: %CallerData{
            actor: "actor-1",
            tenant: "tenant-1"
          }
      }

    action_context = Jidoka.Context.to_action_context(context)

    refute is_struct(action_context)
    refute Map.has_key?(action_context, :__struct__)
    assert action_context.actor == "actor-1"
    assert action_context.tenant == "tenant-1"
    assert action_context.__jidoka__.context == context
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

  test "approval source policy helpers normalize every public input shape" do
    operation = Operation.new!(name: "delete_record", idempotency: :unsafe_once)
    policy = Review.Policy.new!(reason: "review")

    assert Review.Approval.apply_to_operation!(operation, false) == operation

    assert %Operation{approval: %Review.Policy{required: true}} =
             Review.Approval.apply_to_operation!(operation, true)

    assert %Operation{approval: ^policy} = Review.Approval.apply_to_operation!(operation, policy)

    assert [%Operation{approval: %Review.Policy{}}] =
             Review.Approval.apply_to_operations!([operation], true)

    assert_raise ArgumentError, ~r/invalid approval policy/, fn ->
      apply(Review.Approval, :apply_to_operation!, [operation, :invalid])
    end

    assert {:ok, nil} = Review.Approval.policy_for_operation(false, operation)
    assert {:ok, %Review.Policy{}} = Review.Approval.policy_for_operation(true, operation)
    assert {:ok, ^policy} = Review.Approval.policy_for_operation(policy, operation)

    assert {:error, {:invalid_approval_policy, %ArgumentError{}}} =
             Review.Approval.policy_for_operation([:invalid], operation)

    assert {:error, {:invalid_approval_policy, :invalid}} =
             Review.Approval.policy_for_operation(:invalid, operation)

    assert Review.Approval.source_policy_map(nil) == nil
    assert Review.Approval.source_policy_map(false) == nil
    assert %{"required" => true} = Review.Approval.source_policy_map(true)

    assert %{"required" => true, "mode" => "pre_execution", "only" => "unsafe_once"} =
             Review.Approval.source_policy_map(:unsafe_once)

    assert %{"reason" => "review"} = Review.Approval.source_policy_map(policy)
    assert Review.Approval.source_policy_map(:invalid) == nil

    assert %{
             "required" => true,
             "mode" => "pre_execution",
             "predicate" => "Elixir.Jidoka.DataStructsTest.Support.PredicateResults",
             "only" => ["unsafe_once", "delete_record"],
             "except" => ["safe_lookup"],
             "metadata" => %{"level" => "high", "enabled" => true}
           } =
             Review.Approval.source_policy_map(%{
               "required" => true,
               "mode" => :pre_execution,
               "when" => PredicateResults,
               "only" => [:unsafe_once, :delete_record],
               "except" => "safe_lookup",
               "metadata" => %{level: :high, enabled: true}
             })

    assert_raise ArgumentError, ~r/invalid_approval_filter/, fn ->
      Review.Approval.source_policy_map(only: [""])
    end

    assert {:error, {:invalid_approval_filter, :except, 123}} =
             Review.Approval.policy_for_operation(%{except: [123]}, operation)
  end

  test "approval filters accept alternate map operation keys" do
    policy = %{only: [:delete_record, :unsafe_once], reason: "review"}

    assert {:ok, %Review.Policy{}} =
             Review.Approval.policy_for_operation(
               policy,
               %{operation: :delete_record, idempotency: :idempotent}
             )

    assert {:ok, %Review.Policy{}} =
             Review.Approval.policy_for_operation(
               policy,
               %{"operation" => "other", "idempotency" => "unsafe_once"}
             )

    assert {:ok, nil} =
             Review.Approval.policy_for_operation(policy, %{name: 123, idempotency: 123})
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

  test "turn plans reject removed phase defaults and project fixed compiler phases" do
    spec =
      Agent.Spec.new!(
        id: "removed_plan_defaults",
        instructions: "Use the fixed turn process.",
        model: %{provider: :test, id: "model"},
        runtime_defaults: %{workflow_profile: :chat, phases: [:assemble_prompt]}
      )

    assert {:error, {:removed_turn_plan_defaults, [:phases, :workflow_profile]}} =
             Turn.Plan.new(spec)

    plan =
      spec
      |> Map.put(:runtime_defaults, %{})
      |> Turn.Plan.new!()

    refute Map.has_key?(Map.from_struct(plan), :workflow_profile)
    refute Map.has_key?(Map.from_struct(plan), :phases)
    assert Jidoka.project(plan).phases == Jidoka.Adapter.Runic.TurnCompiler.phases()
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
    assert {:ok,
            %Effect.LLMDecision{
              type: :operation,
              operations: [%Effect.OperationRequest{name: "lookup"}]
            }} =
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

  test "model interactions normalize singular and grouped tool calls" do
    singular =
      Effect.LLMDecision.operation("lookup", %{"id" => "A-1"},
        provider_call_id: "provider_call_1",
        provider_metadata: %{"signature" => "sig_1"}
      )

    assert {:ok,
            %Effect.LLMDecision{
              interaction: %Effect.ModelInteraction{
                interaction_id: "interaction_1",
                tool_call_groups: [
                  %Effect.ToolCallGroup{
                    group_id: "group_1",
                    calls: [
                      %Effect.ToolCall{
                        provider_call_id: "provider_call_1",
                        call_index: 0,
                        arguments: %{"id" => "A-1"}
                      }
                    ]
                  }
                ]
              }
            } = normalized} =
             Effect.LLMDecision.with_interaction(singular,
               interaction_id: "interaction_1",
               group_id: "group_1"
             )

    assert Effect.ModelInteraction.to_payload(normalized.interaction) == %{
             interaction_id: "interaction_1",
             tool_call_groups: [
               %{
                 interaction_id: "interaction_1",
                 group_id: "group_1",
                 calls: [
                   %{
                     interaction_id: "interaction_1",
                     group_id: "group_1",
                     provider_call_id: "provider_call_1",
                     call_index: 0,
                     name: "lookup",
                     arguments: %{"id" => "A-1"},
                     provider_metadata: %{"signature" => "sig_1"}
                   }
                 ]
               }
             ]
           }

    parallel =
      Effect.LLMDecision.operations([
        %{name: "read_file", arguments: %{"path" => "a"}, provider_call_id: "call_a"},
        %{name: "read_file", arguments: %{"path" => "b"}, provider_call_id: "call_b"}
      ])

    assert {:ok, interaction} =
             Effect.ModelInteraction.from_decision(parallel,
               interaction_id: "interaction_2",
               group_id: "group_2"
             )

    assert Enum.map(hd(interaction.tool_call_groups).calls, &{&1.provider_call_id, &1.call_index}) ==
             [{"call_a", 0}, {"call_b", 1}]
  end

  test "LLM decisions store one ordered operation list" do
    assert {:ok, legacy} =
             Effect.LLMDecision.from_input(%{
               type: :operation,
               name: "lookup",
               arguments: %{"id" => "A-1"}
             })

    refute Map.has_key?(legacy, :name)
    refute Map.has_key?(legacy, :arguments)
    assert Effect.LLMDecision.name(legacy) == "lookup"
    assert Effect.LLMDecision.arguments(legacy) == %{"id" => "A-1"}
    assert [%Effect.OperationRequest{name: "lookup"}] = legacy.operations

    assert %{type: :operation, operations: [%{name: "lookup"}]} =
             Effect.LLMDecision.to_payload(legacy)

    assert {:error, {:conflicting_operation_decision, _legacy, _operations}} =
             Effect.LLMDecision.from_input(%{
               type: :operation,
               name: "lookup",
               arguments: %{"id" => "A-1"},
               operations: [%{name: "update", arguments: %{"id" => "A-1"}}]
             })

    ordered =
      Effect.LLMDecision.operations([
        %{name: "first", arguments: %{"index" => 1}},
        %{name: "second", arguments: %{"index" => 2}}
      ])

    assert Enum.map(ordered.operations, &{&1.name, &1.arguments}) == [
             {"first", %{"index" => 1}},
             {"second", %{"index" => 2}}
           ]
  end

  test "model interaction validation rejects mismatched group identity and call indexes" do
    call =
      Effect.ToolCall.new!(
        interaction_id: "interaction_1",
        group_id: "group_1",
        call_index: 1,
        name: "lookup"
      )

    assert {:error, :non_contiguous_tool_call_indexes} =
             Effect.ToolCallGroup.new(
               interaction_id: "interaction_1",
               group_id: "group_1",
               calls: [call]
             )

    other_call =
      Effect.ToolCall.new!(
        interaction_id: "interaction_other",
        group_id: "group_1",
        call_index: 0,
        name: "lookup"
      )

    group =
      Effect.ToolCallGroup.new!(
        interaction_id: "interaction_other",
        group_id: "group_1",
        calls: [other_call]
      )

    assert {:error, :tool_call_group_interaction_mismatch} =
             Effect.ModelInteraction.new(
               interaction_id: "interaction_1",
               tool_call_groups: [group]
             )
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
    assert request.request_id =~ @turn_uuid7_regex
    assert %Agent.State{} = request.agent_state

    agent_state = Agent.State.new!(messages: [%{role: :user, content: "prior"}])

    assert {:ok, %Turn.Request{agent_state: ^agent_state, context: %Jidoka.Context{} = context}} =
             Turn.Request.from_input(
               input: "Hello",
               agent_state: agent_state,
               context: %{tenant: "t1"}
             )

    assert Jidoka.Context.data(context) == %{tenant: "t1"}

    trusted_context =
      Jidoka.Context.from_data!(%{tenant: "t1"},
        runtime: %{client: :trusted},
        boundary: :operation,
        operation: "refund_order"
      )

    assert {:ok, %Turn.Request{context: %Jidoka.Context{} = context}} =
             Turn.Request.from_input(input: "Hello", context: trusted_context)

    assert Jidoka.Context.data(context) == %{tenant: "t1"}
    assert Jidoka.Context.runtime(context) == %{}
    assert context.boundary == nil
    assert context.operation == nil
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

  test "agent snapshots reject unsigned serializable maps" do
    state = base_state()
    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert snapshot.schema_version == Snapshot.schema_version()

    assert {:ok, ^snapshot} = Snapshot.from_input(snapshot)

    assert {:error, :unsafe_snapshot_input} =
             snapshot
             |> portable_map()
             |> Snapshot.from_input()
  end

  test "agent snapshot id generation can be explicit or injected" do
    state = base_state()

    assert {:ok, %Snapshot{snapshot_id: "snap_explicit"}} =
             Snapshot.from_turn_state(state, Turn.Cursor.after_prompt(), snapshot_id: "snap_explicit")

    assert {:ok, %Snapshot{snapshot_id: "snap_injected"}} =
             Snapshot.from_turn_state(state, Turn.Cursor.after_prompt(), id_generator: fn "snap" -> "snap_injected" end)
  end

  test "agent snapshots serialize and deserialize through the hibernate contract" do
    state = base_state()
    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    assert {:ok, serialized} = Snapshot.serialize(snapshot)
    assert serialized =~ "jidoka:snapshot:v1:"

    assert {:ok, %Snapshot{} = restored} = Snapshot.deserialize(serialized)
    assert restored.snapshot_id == snapshot.snapshot_id
    assert restored.cursor.phase == :after_prompt
    assert restored.turn_state.plan.spec.id == "snapshot_agent"
  end

  test "legacy snapshots discard copied turn authorities" do
    state = base_state()
    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())

    conflicting_spec =
      Agent.Spec.new!(
        id: "conflicting_agent",
        instructions: "This copied value is not authoritative.",
        model: %{provider: :test, id: "other-model"}
      )

    legacy_state =
      state
      |> Map.from_struct()
      |> Map.put(:spec, conflicting_spec)
      |> Map.put(:operation_plan, %{name: "stale", arguments: %{}})
      |> Map.put(
        :plan,
        state.plan
        |> Map.from_struct()
        |> Map.put(:workflow_profile, :chat)
        |> Map.put(:phases, [:stale_phase])
      )

    legacy_snapshot = snapshot |> Map.from_struct() |> Map.put(:turn_state, legacy_state)

    assert {:ok, restored} = Snapshot.new(legacy_snapshot)
    assert restored.turn_state.plan.spec.id == "snapshot_agent"
    refute Map.has_key?(Map.from_struct(restored.turn_state), :spec)
    refute Map.has_key?(Map.from_struct(restored.turn_state), :operation_plan)
    refute Map.has_key?(Map.from_struct(restored.turn_state.plan), :workflow_profile)
    refute Map.has_key?(Map.from_struct(restored.turn_state.plan), :phases)
  end

  test "agent snapshot restore keeps model interaction and tool-call identifiers" do
    decision =
      Effect.LLMDecision.operations([
        %{
          name: "lookup",
          arguments: %{"id" => "A-1"},
          provider_call_id: "provider_call_1",
          provider_metadata: %{"opaque" => "provider_value"}
        }
      ])

    assert {:ok, decision} =
             Effect.LLMDecision.with_interaction(decision,
               interaction_id: "interaction_1",
               group_id: "group_1",
               provider_metadata: %{"response_id" => "response_1"}
             )

    snapshot =
      base_state()
      |> Map.put(:llm_result, decision)
      |> Snapshot.from_turn_state!(Turn.Cursor.after_prompt())

    assert {:ok, restored} = snapshot |> Snapshot.serialize!() |> Snapshot.deserialize()

    assert %Effect.LLMDecision{
             interaction: %Effect.ModelInteraction{
               interaction_id: "interaction_1",
               provider_metadata: %{"response_id" => "response_1"},
               tool_call_groups: [
                 %Effect.ToolCallGroup{
                   interaction_id: "interaction_1",
                   group_id: "group_1",
                   calls: [
                     %Effect.ToolCall{
                       interaction_id: "interaction_1",
                       group_id: "group_1",
                       provider_call_id: "provider_call_1",
                       call_index: 0,
                       provider_metadata: %{"opaque" => "provider_value"}
                     }
                   ]
                 }
               ]
             }
           } = restored.turn_state.llm_result
  end

  test "snapshot serialization rejects non-portable runtime values" do
    state = base_state()
    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{callback: fn -> :ok end}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :callback], :function}} =
             Snapshot.serialize(snapshot)

    snapshot = Snapshot.from_turn_state!(state, Turn.Cursor.after_prompt())
    snapshot = %{snapshot | metadata: %{wrapped: {:ok, fn -> :ok end}}}

    assert {:error, {:non_serializable_snapshot_value, [:metadata, :wrapped, 1], :function}} =
             Snapshot.serialize(snapshot)
  end

  test "turn results require a finished state" do
    %Turn.State{} = state = base_state()
    finished = %{state | status: :finished, result: "done"}

    assert %Turn.Result{content: "done"} = Turn.Result.from_turn_state!(finished)

    assert_raise FunctionClauseError, fn ->
      Turn.Result.from_turn_state!(state)
    end
  end

  test "turn state accepts legacy pending effects and rejects unexpected results" do
    %Turn.State{} = state = base_state()
    intent = Effect.Intent.new(:llm, %{request_id: state.request.request_id}, id: "legacy-llm")

    legacy_attrs =
      state
      |> Map.from_struct()
      |> Map.delete(:pending_effects)
      |> Map.put(:pending_effect, intent)
      |> Map.put(:spec, state.plan.spec)
      |> Map.put(:operation_plan, [])

    assert {:ok, %Turn.State{pending_effects: [^intent]} = legacy} = Turn.State.new(legacy_attrs)
    assert Turn.State.pending_effect?(legacy)
    refute Turn.State.pending_effect?(state)
    assert Turn.State.pop_pending_effect(state) == state

    assert {:error, {:unexpected_effect_result, ^state, :invalid}} =
             Turn.State.apply_effect_result(state, :invalid)

    invalid_output = Effect.Result.ok(intent, :invalid)

    assert {:error, {:invalid_llm_output, :invalid}} =
             legacy |> Turn.State.apply_effect_result(invalid_output)

    nil_legacy = legacy_attrs |> Map.delete(:pending_effect) |> Map.put("pending_effect", nil)
    assert {:ok, %Turn.State{pending_effects: []}} = Turn.State.new(nil_legacy)
    assert {:error, _reason} = Turn.State.new(:invalid)
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
