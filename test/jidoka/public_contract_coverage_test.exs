defmodule Jidoka.PublicContractCoverageTest.NamedAgent do
  @moduledoc false
  def __jidoka_agent_id__, do: "named-agent"
end

defmodule Jidoka.PublicContractCoverageTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.ExecutionEnvironment.{Binding, SecurityProfile}
  alias Jidoka.Extension.{CapabilitySet, Error, OperationSource}
  alias Jidoka.Operation.Source.JidoAction
  alias Jidoka.Runtime.Controls.OperationContext
  alias Jidoka.Runtime.DurableCheckpoint
  alias Jidoka.Runtime.Limits.{Exceeded, Ledger}
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn
  alias Jidoka.Workflow.RetryPolicy

  @digest "sha256:" <> String.duplicate("a", 64)

  test "builds and projects low-level extension contracts" do
    error = Error.new(:extension_failed, %{slot: :tools})

    assert Error.to_map(error) == %{
             "code" => "extension_failed",
             "message" => "extension resolution failed",
             "details" => %{"slot" => "tools"}
           }

    assert {:ok, %CapabilitySet{values: ["files.read", "tools.call"]} = set} =
             CapabilitySet.new([:"tools.call", "files.read", "tools.call"])

    assert {:ok, ^set} = CapabilitySet.new(set)
    assert CapabilitySet.to_map(set) == %{"version" => 1, "values" => ["files.read", "tools.call"]}
    assert {:error, {:invalid_extension_capabilities, ["bad value"]}} = CapabilitySet.new(["bad value"])
    assert {:error, {:invalid_extension_capabilities, :invalid}} = CapabilitySet.new(:invalid)
    assert_raise ArgumentError, fn -> CapabilitySet.new!(["bad value"]) end
  end

  test "compiles extension and Jido action operation sources" do
    operation = Operation.new!(name: "lookup")
    handler = fn arguments, _context -> {:ok, arguments} end
    source = %OperationSource{namespace: "test", operations: [operation], handlers: %{"lookup" => handler}}

    assert {:ok, [^operation]} = OperationSource.operations(source, [])
    assert {:ok, capability} = OperationSource.capability(source, [])

    assert {:ok, [%{"kind" => "extension", "namespace" => "test"}]} =
             OperationSource.metadata(source, [])

    assert {:ok, compiled} = OperationSource.compile(source, [])
    assert compiled.operations == [operation]

    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{id: 1}})
    context = Jidoka.Context.from_data!(%{})
    assert {:ok, %{id: 1}} = capability.(intent, Effect.Journal.new!(), context)

    action_source = JidoAction.new!([], [operation], metadata: [%{kind: "action"}])
    assert {:ok, [^operation]} = JidoAction.operations(action_source, [])
    assert {:ok, action_capability} = JidoAction.capability(action_source, [])
    assert is_function(action_capability, 3)
    assert {:ok, [%{kind: "action"}]} = JidoAction.metadata(action_source, [])
    assert {:ok, action_compiled} = JidoAction.compile(action_source, [])
    assert action_compiled.operations == [operation]
  end

  test "builds portable tool-call data and rejects invalid data" do
    attrs = %{
      interaction_id: "interaction-1",
      group_id: "group-1",
      provider_call_id: "provider-1",
      call_index: 0,
      name: "lookup",
      arguments: %{id: 1},
      provider_metadata: %{source: "test"}
    }

    assert {:ok, %Effect.ToolCall{} = call} = Effect.ToolCall.new(attrs)
    assert {:ok, ^call} = Effect.ToolCall.from_input(call)
    assert {:ok, %Effect.ToolCall{}} = Effect.ToolCall.from_input(Map.to_list(attrs))
    assert Effect.ToolCall.schema()
    assert Effect.ToolCall.to_payload(call).provider_call_id == "provider-1"

    minimal =
      Effect.ToolCall.new!(
        interaction_id: "interaction-2",
        group_id: "group-2",
        call_index: 0,
        name: "plain"
      )

    refute Map.has_key?(Effect.ToolCall.to_payload(minimal), :provider_call_id)
    refute Map.has_key?(Effect.ToolCall.to_payload(minimal), :provider_metadata)
    assert {:error, _reason} = Effect.ToolCall.new(%{})
    assert_raise ArgumentError, fn -> Effect.ToolCall.new!(%{}) end
  end

  test "normalizes runtime count and limit evidence contracts" do
    assert Jidoka.Loop.Counts.schema()
    assert {:ok, %Jidoka.Loop.Counts{} = counts} = Jidoka.Loop.Counts.new()
    assert counts.user_turns == 0
    assert Jidoka.Loop.Counts.new!(%{user_turns: 2}).user_turns == 2
    assert {:error, _reason} = Jidoka.Loop.Counts.new(user_turns: -1)

    assert Ledger.schema()
    assert {:ok, %Ledger{} = ledger} = Ledger.new()
    assert ledger.total_cost == 0
    assert Ledger.new!(tool_calls: 2).tool_calls == 2
    assert {:error, _reason} = Ledger.new(total_tokens: -1)

    assert :environment in Exceeded.kinds()
    assert Exceeded.schema()

    assert {:ok, %Exceeded{kind: :total_tokens}} =
             Exceeded.new(kind: :total_tokens, limit: 10, observed: 11)

    assert Exceeded.new!(kind: :total_cost, limit: 1.0, observed: 1.5).observed == 1.5
    assert {:error, _reason} = Exceeded.new(kind: :invalid, limit: 1, observed: 2)
  end

  test "validates built-in input and context controls" do
    context = Jidoka.Context.from_data!(%{tenant_id: "tenant-1"}, input: "hello")

    assert :cont = Jidoka.Controls.MaxInputLength.call(%{ctx: context, metadata: %{max: 5}})

    assert {:block, {:input_too_long, 5, 4}} =
             Jidoka.Controls.MaxInputLength.call(%{ctx: context, metadata: %{"max_length" => "4"}})

    assert {:error, :missing_jidoka_context} = Jidoka.Controls.MaxInputLength.call(%{})
    assert {:error, :missing_max_input_length} = Jidoka.Controls.MaxInputLength.call(context)

    assert {:error, {:invalid_max_input_length, "bad"}} =
             Jidoka.Controls.MaxInputLength.call(%{ctx: context, metadata: %{max: "bad"}})

    assert {:error, {:invalid_max_input_length, 0}} =
             Jidoka.Controls.MaxInputLength.call(%{ctx: context, metadata: %{max: 0}})

    assert :cont = Jidoka.Controls.RequireContext.call(%{ctx: context, metadata: %{keys: [:tenant_id]}})

    assert {:block, {:missing_context_keys, ["user_id", "empty"]}} =
             Jidoka.Controls.RequireContext.call(%{
               ctx: Jidoka.Context.from_data!(%{tenant_id: "tenant-1", empty: nil}),
               metadata: %{"required" => ["user_id", :empty]}
             })

    assert {:error, :missing_jidoka_context} = Jidoka.Controls.RequireContext.call(%{})
    assert {:error, :missing_required_context_keys} = Jidoka.Controls.RequireContext.call(context)

    assert {:error, {:invalid_context_key, ""}} =
             Jidoka.Controls.RequireContext.call(%{ctx: context, metadata: %{keys: ""}})

    assert {:error, {:invalid_context_key, 123}} =
             Jidoka.Controls.RequireContext.call(%{ctx: context, metadata: %{keys: [123]}})
  end

  test "evaluates approval controls for required, skipped, and invalid policies" do
    context = Jidoka.Context.from_data!(%{})

    required = struct(OperationContext, metadata: %{policy: true}, ctx: context)
    assert {:interrupt, :approval_required} = Jidoka.Controls.RequireApproval.call(required)

    skipped = struct(OperationContext, metadata: %{policy: false}, ctx: context)
    assert :cont = Jidoka.Controls.RequireApproval.call(skipped)

    default_policy = struct(OperationContext, metadata: :invalid, ctx: context)
    assert {:interrupt, :approval_required} = Jidoka.Controls.RequireApproval.call(default_policy)

    invalid = struct(OperationContext, metadata: %{policy: :invalid}, ctx: context)

    assert {:error, {:invalid_approval_policy, {:invalid_review_policy, :invalid}}} =
             Jidoka.Controls.RequireApproval.call(invalid)
  end

  test "builds server options for lists, maps, named agents, and plain modules" do
    named = Jidoka.PublicContractCoverageTest.NamedAgent

    assert [id: "named-agent", jido: Jidoka.Jido, agent: ^named] =
             Jidoka.Agent.ServerOptions.child_opts(named, [])

    assert %{id: "custom", agent: ^named, jido: :custom_jido} =
             Jidoka.Agent.ServerOptions.child_opts(named, %{id: "custom", jido: :custom_jido})

    assert Jidoka.Agent.ServerOptions.child_opts(UnknownAgent, [])[:id] == "unknown_agent"
  end

  test "builds and projects execution environment profiles and bindings" do
    profile_attrs = [
      profile_id: "restricted",
      revision: 1,
      digest: @digest,
      adapter_id: "sandbox",
      required_isolation: :container,
      required_network: :disabled,
      required_workspace: :ephemeral
    ]

    assert SecurityProfile.version() == 1
    assert SecurityProfile.schema()
    assert {:ok, %SecurityProfile{} = profile} = SecurityProfile.new(profile_attrs)
    assert SecurityProfile.new!(profile_attrs) == profile
    assert SecurityProfile.to_map(profile)["profile_id"] == "restricted"

    binding_attrs = [
      adapter_id: "sandbox",
      adapter_version: "1.0",
      profile_id: "restricted",
      profile_digest: @digest,
      resource_ref: "environment-1"
    ]

    assert Binding.version() == 1
    assert Binding.schema()
    assert {:ok, %Binding{} = binding} = Binding.new(binding_attrs)
    assert Binding.new!(binding_attrs) == binding
    assert Binding.to_map(binding)["resource_ref"] == "environment-1"
    assert {:error, _reason} = Binding.new(Keyword.put(binding_attrs, :state, :invalid))
  end

  test "normalizes retry policies and formats DSL errors" do
    assert RetryPolicy.schema()
    assert RetryPolicy.backoff_types() == [:fixed, :exponential]
    assert {:ok, nil} = RetryPolicy.new(nil)
    assert RetryPolicy.new!(nil) == nil

    assert {:ok, %RetryPolicy{max_attempts: 3, backoff: %{type: :exponential, min: 1, max: 5}}} =
             RetryPolicy.new(max_attempts: "3", backoff: [type: :exponential, min: "1", max: "5"])

    assert %RetryPolicy{max_attempts: 1} = RetryPolicy.new!(%{})
    assert {:error, _reason} = RetryPolicy.new(%{max_attempts: 0})

    error =
      Jidoka.Workflow.Dsl.Error.exception(
        message: "Invalid step",
        path: [:steps, :lookup],
        value: %{bad: true},
        hint: "Use a function step.",
        module: __MODULE__
      )

    message = Exception.message(error)
    assert message =~ "Invalid step"
    assert message =~ "Section path: steps.lookup"
    assert message =~ "Invalid value: %{bad: true}"
    assert message =~ "Fix: Use a function step."

    short = Jidoka.Workflow.Dsl.Error.exception(message: "Bad", path: :workflow)
    assert Exception.message(short) =~ "Section path: workflow"
  end

  test "normalizes sequence request and result public contracts" do
    request =
      Sequence.Request.new(
        request_id: "request-1",
        controller: self(),
        session_id: "session-1",
        started_at_ms: 1
      )

    assert Sequence.Request.schema()
    assert Sequence.Request.request?(request)
    refute Sequence.Request.request?(:invalid)
    assert {:ok, controller} = Sequence.Request.controller(request)
    assert controller == self()
    assert {:error, :invalid_sequence_request} = Sequence.Request.controller(:invalid)

    spec = Jidoka.agent!(id: "sequence-contract", instructions: "Reply.", model: %{provider: :test, id: "model"})
    assert {:ok, session} = Jidoka.Session.Data.start(spec, session_id: "session-1")

    assert Sequence.Result.schema()
    assert Sequence.Result.statuses() == [:completed, :error, :hibernated, :cancelled]

    assert {:ok, %Sequence.Result{status: :completed}} =
             Sequence.Result.new(status: :completed, session: session)

    assert %Sequence.Result{status: :completed} =
             Sequence.Result.new!(status: :completed, session: session)

    assert {:error, _reason} = Sequence.Result.new(status: :invalid, session: session)
  end

  test "normalizes all durable checkpoint callback results and failures" do
    state = turn_state()
    intent = Effect.Intent.new(:operation, %{name: "lookup", arguments: %{}})

    assert :ok = DurableCheckpoint.persist(state, intent, :before, [])
    assert :ok = DurableCheckpoint.persist(state, intent, :before, durable_checkpoint: fn _, _, _ -> :ok end)

    assert :ok =
             DurableCheckpoint.persist(state, intent, :before, durable_checkpoint: fn _, _, _ -> {:ok, :stored} end)

    assert {:error, :store_failed} =
             DurableCheckpoint.persist(state, intent, :before,
               durable_checkpoint: fn _, _, _ -> {:error, :store_failed} end
             )

    assert {:error, {:invalid_durable_checkpoint_result, :invalid}} =
             DurableCheckpoint.persist(state, intent, :before, durable_checkpoint: fn _, _, _ -> :invalid end)

    assert {:error, {:durable_checkpoint_failed, %RuntimeError{}}} =
             DurableCheckpoint.persist(state, intent, :before, durable_checkpoint: fn _, _, _ -> raise "failed" end)

    assert {:error, {:durable_checkpoint_failed, {:throw, :failed}}} =
             DurableCheckpoint.persist(state, intent, :before, durable_checkpoint: fn _, _, _ -> throw(:failed) end)
  end

  test "projects safe metadata and control names" do
    assert Jidoka.Projection.Metadata.agent(%{dsl_module: String, keep: :yes}) == %{keep: :yes}
    assert Jidoka.Projection.Metadata.agent(:plain) == :plain

    assert Jidoka.Projection.Metadata.turn_plan(%{dsl_operation_source_digest: "private", keep: 1}) ==
             %{keep: 1}

    assert Jidoka.Projection.Metadata.turn_plan(:plain) == :plain

    assert Jidoka.Projection.Metadata.operation(%{parameters_schema: %{"type" => "object"}, keep: 1}) ==
             %{"parameters_schema?" => true, keep: 1}

    assert Jidoka.Projection.Metadata.operation(:plain) == :plain
    assert Jidoka.Projection.Metadata.control_name(Jidoka.Controls.MaxInputLength) == "max_input_length"
    assert Jidoka.Projection.Metadata.control_name(String) == "String"
  end

  defp turn_state do
    spec = Jidoka.agent!(id: "checkpoint-contract", instructions: "Reply.", model: %{provider: :test, id: "model"})
    plan = Turn.Plan.new!(spec)
    request = Turn.Request.new!(%{input: "hello"}, request_id: "checkpoint-request")
    Turn.State.new!(plan: plan, request: request, agent_state: request.agent_state)
  end
end
