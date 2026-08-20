defmodule Jidoka.LowCoverageContractTest do
  use ExUnit.Case, async: true

  alias Jidoka.Debug.RequestSummary
  alias Jidoka.Inspection.Preflight
  alias Jidoka.Memory.WriteResult
  alias Jidoka.Policy.Request
  alias Jidoka.Runtime.Controls.OperationContext
  alias Jidoka.Runtime.Limits
  alias Jidoka.Session.Lease
  alias Jidoka.Session.Sequence
  alias Jidoka.Turn

  test "small public contracts expose schemas, versions, and safe constructors" do
    assert Jidoka.Review.LegacyControl.name() == "legacy_review"
    assert RequestSummary.schema()
    assert Preflight.schema()
    assert WriteResult.schema()
    assert OperationContext.schema()
    assert Lease.schema()

    assert Request.version() == 1
    assert Request.effect_classes() == [:llm, :operation, :execution_environment, :extension_process]
    assert Request.schema()

    assert {:ok, %Request{}} =
             Request.new(
               effect_class: :operation,
               action: "read",
               request_id: "request-contract",
               resource: %{path: ["safe"]}
             )

    assert {:error, _reason} =
             Request.new(
               effect_class: :operation,
               action: "unsafe",
               request_id: "request-unsafe",
               resource: %{nested: URI.parse("https://example.test"), owner: self()}
             )

    assert {:ok, %Limits.Evidence{}} =
             Limits.Evidence.new(
               status: :within,
               applied: limits(),
               observed: observed(),
               exceeded: nil
             )

    assert {:ok, %Limits.Observed{}} = Limits.Observed.new(Map.from_struct(observed()))

    assert {:ok, %Lease{lease_id: "lease-contract"}} =
             Lease.acquire("request-contract", 10, 20, id_generator: fn "lease" -> "lease-contract" end)

    assert {:error, {:invalid_session_lease, :bad, 10, 0}} = Lease.acquire(:bad, 10, 0)

    assert {:error, _reason} = Sequence.Step.new(%{})
    assert {:error, _reason} = Sequence.Terminal.new(%{})
  end

  test "unknown internal errors accept string and structured causes" do
    string_error = Jidoka.Error.Internal.UnknownError.exception(error: "plain failure")
    structured_error = Jidoka.Error.Internal.UnknownError.exception(error: {:failure, 1})

    assert Exception.message(string_error) == "plain failure"
    assert Exception.message(structured_error) == inspect({:failure, 1})
  end

  test "tool-source input helpers reject unsafe or malformed declarations" do
    common = Jidoka.Agent.ToolSources.Common

    assert common.normalize_name_list!(nil, "name") == []
    assert common.normalize_name_list!(:safe_name, "name") == ["safe_name"]
    assert common.normalize_string!(:value, "value") == "value"
    assert common.normalize_string_list!(nil, "value") == []
    assert common.normalize_string_list!(" value ", "value") == ["value"]
    assert common.normalize_metadata!(nil) == %{}
    assert common.metadata_value("value") == "value"
    assert common.metadata_value({:value, 1}) == inspect({:value, 1})

    assert_raise ArgumentError, ~r/must expose/, fn -> common.operation_from_action!(__MODULE__) end
    assert_raise ArgumentError, ~r/could not compile action/, fn -> common.operation_from_action!(MissingAction) end
    assert_raise ArgumentError, ~r/must be an atom or string/, fn -> common.normalize_name!(1, "name") end
    assert_raise ArgumentError, ~r/cannot include empty strings/, fn -> common.normalize_string!(" ", "value") end
    assert_raise ArgumentError, ~r/entries must be atoms or strings/, fn -> common.normalize_string!(1, "value") end
    assert_raise ArgumentError, ~r/tool metadata must be a map/, fn -> common.normalize_metadata!(:bad) end
  end

  test "small data modules return typed errors for malformed inputs" do
    assert Jidoka.Session.Replay.schema()
    assert [_terminal | _rest] = Jidoka.Event.Order.terminal_events()
    assert {:error, :empty_events} = Jidoka.Event.Order.validate([])
    assert {:error, {:missing_request_id, 0}} = Jidoka.Event.Order.validate([struct(Jidoka.Event)])

    assert {:error, {:invalid_operation_group, :bad}} = Jidoka.Effect.OperationGroup.new(:bad)
    llm_intent = Jidoka.Effect.Intent.new(:llm, %{})

    assert_raise ArgumentError, ~r/invalid operation group/, fn ->
      Jidoka.Effect.OperationGroup.new!([llm_intent])
    end

    intent = Jidoka.Effect.Intent.new(:operation, %{name: "one"})
    group = Jidoka.Effect.OperationGroup.new!([intent])
    assert Jidoka.Effect.OperationGroup.member?(group, intent)
    refute Jidoka.Effect.OperationGroup.member?(group, :other)

    assert_raise ArgumentError, ~r/invalid extension request/, fn -> Jidoka.Extension.Request.new!(id: "") end
    assert {:error, {:invalid_extension_requests, :bad}} = Jidoka.Extension.Request.normalize_list(:bad)

    assert_raise ArgumentError, ~r/invalid turn request/, fn -> Jidoka.Turn.Request.new!(%{}) end
    assert {:error, {:invalid_request_attributes, :bad}} = Jidoka.Turn.Request.from_input(:bad)

    assert_raise ArgumentError, fn -> Jidoka.Extension.Registration.new!(%{}) end
    assert {:error, _reason} = Jidoka.Extension.Registration.new(%{modes: :bad})

    assert Jidoka.Review.Request.schema()
    assert {:error, _reason} = Jidoka.Review.Request.from_input(%{})
    assert_raise ArgumentError, fn -> Jidoka.Review.Request.new!(%{}) end

    assert_raise ArgumentError, ~r/invalid memory route/, fn -> Jidoka.Memory.Route.new!(kind: :namespace) end
    assert {:error, _reason} = Jidoka.Memory.Route.new(kind: :global, namespace: "conflict")

    assert {:error, :invalid_execution_environment_registration} =
             Jidoka.ExecutionEnvironment.Registration.new(:bad)

    assert_raise ArgumentError, ~r/invalid execution registration/, fn ->
      Jidoka.ExecutionEnvironment.Registration.new!([])
    end

    assert_raise ArgumentError, ~r/invalid workflow step/, fn -> Jidoka.Workflow.Step.new!(%{}) end
    assert {:error, _reason} = Jidoka.Workflow.Step.from_input(%{kind: :action})

    assert {:error, _reason} = Jidoka.Review.Interrupt.new(%{})
    assert {:error, _reason} = Jidoka.Review.Interrupt.from_input(%{})

    assert {:error, {:invalid_workflow_outcomes, :bad}} = Jidoka.Workflow.Suspension.find(:bad)
    assert {:ok, nil} = Jidoka.Workflow.Suspension.find(%{})
  end

  test "public facade and harness convenience functions preserve typed errors" do
    spec = agent_spec()
    session = Jidoka.Session.Data.start(spec, session_id: "facade-contract") |> elem(1)
    running = Jidoka.Session.Data.put_request(session, Turn.Request.new!(input: "active"))

    assert {:error, {:missing_session_snapshot, "facade-contract"}} = Jidoka.fork_session(session)
    assert {:error, :missing_harness_store} = Jidoka.recover_session("facade-contract")
    assert {:error, _reason} = Jidoka.resume(:invalid)
    assert {:error, _reason} = Jidoka.approve(session, "missing-review")
    assert {:error, _reason} = Jidoka.deny(session, "missing-review")
    assert is_binary(Jidoka.format_error(:plain_error))
    assert is_map(Jidoka.error_to_map(:plain_error))
    assert is_exception(Jidoka.normalize_error(:plain_error))

    assert {:ok, async_request} = Jidoka.chat_async(running, "blocked")
    assert {:error, {:session_already_running, "facade-contract"}} = Jidoka.await(async_request)

    assert {:error, _reason} = Jidoka.Harness.run_turn(:invalid, "input")

    assert {:error, {:session_already_running, "facade-contract"}} =
             Jidoka.Harness.run_session(running, "input")

    assert {:error, :missing_harness_store} = Jidoka.Harness.recover_session("facade-contract")
    assert {:error, :missing_memory_store} = Jidoka.Harness.write_memory(spec, "remember")
    assert {:ok, %Turn.Plan{}} = Jidoka.Harness.plan(spec)

    {:ok, pid} = Jidoka.Session.Store.InMemory.start_link()
    store = {Jidoka.Session.Store.InMemory, pid: pid}
    assert {:ok, []} = Jidoka.Harness.store_list_recoverable(store)
    assert {:ok, []} = Jidoka.Session.Store.list_recoverable(store)

    other = %Jidoka.Session.Data{session | session_id: "other"}

    assert {:error, {:stale_session_lease, "facade-contract", "missing"}} =
             Jidoka.Session.Store.commit_transition(session, "missing", other, clock: fn -> 1 end)
  end

  test "config and prepared-turn boundaries cover defaults and invalid values" do
    assert {:error, _reason} = Jidoka.Config.normalize_model_spec(nil)
    assert {:error, _reason} = Jidoka.Config.normalize_model_spec("bad")
    assert_raise ArgumentError, fn -> Jidoka.Config.normalize_model_spec!(nil) end
    assert {:error, _reason} = Jidoka.Config.normalize_generation(:bad)
    assert_raise ArgumentError, fn -> Jidoka.Config.normalize_generation!(:bad) end
    assert {:ok, 12} = Jidoka.Config.normalize_positive_integer("12", :limit)

    assert {:error, {:limit, "bad", :not_positive_integer}} =
             Jidoka.Config.normalize_positive_integer("bad", :limit)

    assert {:error, {:limit, 0, :not_positive_integer}} = Jidoka.Config.normalize_positive_integer(0, :limit)
    assert_raise ArgumentError, fn -> Jidoka.Config.normalize_positive_integer!(0, :limit) end

    plan = Turn.Plan.new!(agent_spec())
    request = Turn.Request.new!(input: "prepared")
    assert {:ok, %Turn.Prepared{memory: nil, limits: nil}} = Turn.Prepared.new(plan, request)
    assert {:error, {:invalid_resolved_memory, :bad}} = Turn.Prepared.new(plan, request, memory: :bad)
    assert {:error, {:invalid_resolved_limits, :bad}} = Turn.Prepared.new(plan, request, limits: :bad)

    overflow_spec =
      Jidoka.Agent.Spec.new!(
        id: "prepared-overflow",
        instructions: "Reply.",
        model: %{provider: :test, id: "model"},
        runtime_defaults: %{context_policy: %{input_budget: 1, minimum_recent_turns: 0}}
      )

    overflow_plan = Turn.Plan.new!(overflow_spec)
    overflow_request = Turn.Request.new!(input: String.duplicate("x", 100))

    overflow_state =
      Turn.State.new!(
        plan: overflow_plan,
        request: overflow_request,
        agent_state: overflow_request.agent_state
      )

    assert %Turn.State{context_projection_error: {:context_input_budget_exceeded, _evidence}} =
             Turn.Prepared.prepare_state!(overflow_state)

    cursor = Jidoka.Workflow.Loop.Cursor.new!(:one, %{}, 1)

    assert {:error, {:workflow_suspension_step_mismatch, :two, :one}} =
             Jidoka.Workflow.Suspension.find(%{two: %{status: :suspended, cursor: cursor}})

    assert {:error, {:invalid_workflow_suspension_outcome, :one, %{status: :suspended}}} =
             Jidoka.Workflow.Suspension.find(%{one: %{status: :suspended}})

    identity =
      Jidoka.Extension.Identity.new!(
        id: "acme.extension",
        source_type: :built_in,
        source_ref: "registry:acme-extension",
        release: "1.0.0",
        content_hash: "sha256:" <> String.duplicate("a", 64),
        trust: :trusted
      )

    assert {:ok, %Jidoka.Extension.Registration{modes: [:automation, :interactive]}} =
             Jidoka.Extension.Registration.new(identity: identity, modes: ["interactive", "automation"])

    assert {:error, _reason} = Jidoka.Extension.Registration.new(identity: identity, modes: :bad)

    assert_raise ArgumentError, ~r/invalid session environment/, fn ->
      Jidoka.Session.Environment.new!(%{})
    end

    invalid_interrupt = struct(Jidoka.Review.Interrupt)

    assert_raise ArgumentError, ~r/invalid review request/, fn ->
      Jidoka.Review.Request.from_interrupt!(invalid_interrupt)
    end

    operation_intent = Jidoka.Effect.Intent.new(:operation, %{name: "known"})
    operation_group = Jidoka.Effect.OperationGroup.new!([operation_intent])

    assert {:error, {:operation_group_unknown_intent, _id}} =
             Jidoka.Effect.OperationGroup.complete(operation_group, :unknown)
  end

  defp limits do
    Limits.Applied.new!(max_model_turns: 2, turn_timeout_ms: 100)
  end

  defp agent_spec do
    Jidoka.Agent.Spec.new!(
      id: "low_coverage_contract",
      instructions: "Return a test answer.",
      model: %{provider: :test, id: "model"}
    )
  end

  defp observed do
    Limits.Observed.new!(
      user_turns: 0,
      model_steps: 0,
      model_turns: 0,
      tool_call_groups: 0,
      tool_calls: 0,
      provider_attempts: 0,
      recovery_steps: 0,
      observation_bytes: 0,
      result_repairs: 0,
      sequence_duration_ms: 0,
      usage: %{},
      environment: %{}
    )
  end
end
