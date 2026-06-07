defmodule Jidoka.ControlsIntegrationTest do
  use ExUnit.Case, async: true

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.IntegrationSupport.AuditControl
  alias Jidoka.IntegrationSupport.AuditInputControl
  alias Jidoka.IntegrationSupport.BlockInputControl
  alias Jidoka.IntegrationSupport.ControlledLookupAction
  alias Jidoka.IntegrationSupport.ControlledLookupAgent
  alias Jidoka.IntegrationSupport.InputControlledLookupAgent
  alias Jidoka.IntegrationSupport.OperationDecisionAgent
  alias Jidoka.Runtime.LocalOperations
  alias Jidoka.Turn

  import Jidoka.TestSupport,
    only: [count_results: 2, operation_capability_index: 2, operation_control_index: 2, timeline: 1]

  @live_enabled? not is_nil(System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY"))

  test "operation controls compile into spec data and run before operation capabilities" do
    spec = ControlledLookupAgent.spec()

    assert [
             %Agent.Spec.Controls.Operation{
               control: ApprovalControl,
               match: %{kind: :action, name: "controlled_lookup"}
             },
             %Agent.Spec.Controls.Operation{
               control: AuditControl,
               match: %{}
             }
           ] = spec.controls.operations

    assert %{
             controls: %{
               operations: [
                 %{
                   control: "require_approval",
                   match: %{kind: :action, name: "controlled_lookup"}
                 },
                 %{control: "audit_control", match: %{}}
               ]
             }
           } = Jidoka.project(spec)

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok,
           %{
             type: :operation,
             name: "controlled_lookup",
             arguments: %{"id" => "ctrl_123"}
           }}

        1 ->
          {:ok, %{type: :final, content: "Controlled lookup ctrl_123 is controlled-value."}}
      end
    end

    request =
      Turn.Request.new!(
        input: "Look up ctrl_123",
        context: %{test_pid: self()}
      )

    assert {:ok, %Turn.Result{} = result} =
             ControlledLookupAgent.run_turn(request,
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    assert_receive {:operation_control_called, "require_approval", "controlled_lookup", %{"id" => "ctrl_123"}}

    assert_receive {:operation_control_called, "audit_control", "controlled_lookup", %{"id" => "ctrl_123"}}

    assert result.content == "Controlled lookup ctrl_123 is controlled-value."
    assert_receive {:controlled_lookup_called, "ctrl_123"}

    timeline = timeline(result.events)

    require_approval_index = operation_control_index(timeline, "require_approval")
    audit_index = operation_control_index(timeline, "audit_control")
    capability_index = operation_capability_index(timeline, "controlled_lookup")

    assert is_integer(require_approval_index)
    assert is_integer(audit_index)
    assert is_integer(capability_index)
    assert require_approval_index < capability_index
    assert audit_index < capability_index
  end

  test "imported operation controls normalize string matches to the same spec shape as DSL" do
    yaml = """
    agent:
      id: controlled_lookup_agent
      model:
        provider: test
        id: model
      instructions: Use controlled_lookup before answering controlled lookup questions.
    tools:
      actions:
        - controlled_lookup
    controls:
      operations:
        - control: require_approval
          when:
            kind: action
            name: controlled_lookup
        - control: audit_control
    """

    assert {:ok, imported_spec} =
             Jidoka.import(yaml,
               format: :yaml,
               registries: registries()
             )

    assert semantic_projection(imported_spec) ==
             semantic_projection(ControlledLookupAgent.spec())
  end

  test "input controls compile into spec data and run before the first model effect" do
    spec = InputControlledLookupAgent.spec()

    assert spec.controls.max_turns == 3
    assert spec.controls.timeout_ms == 1_000

    assert [
             %Agent.Spec.Controls.Input{control: AuditInputControl},
             %Agent.Spec.Controls.Input{control: BlockInputControl}
           ] = spec.controls.inputs

    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "allowed"}} end

    request =
      Turn.Request.new!(
        input: "allowed lookup",
        context: %{test_pid: self()}
      )

    assert {:ok, %Turn.Result{content: "allowed"} = result} =
             InputControlledLookupAgent.run_turn(request, llm: llm)

    assert_received {:input_control_called, "allowed lookup"}

    assert [
             %{event: :control_allowed, data: %{control: "audit_input_control"}},
             %{event: :control_allowed, data: %{control: "block_input_control"}}
             | _events
           ] = timeline(result.events)
  end

  test "input controls block the turn before LLM or operation effects run" do
    llm = fn _intent, _journal, _ctx -> flunk("blocked input must not call the LLM") end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "block_input_control",
                boundary: :input,
                cause: :blocked_input
              }
            }} = InputControlledLookupAgent.run_turn("blocked lookup", llm: llm)
  end

  test "built-in input controls require context and limit input length" do
    spec =
      Agent.Spec.new!(
        id: "builtin_input_controls_agent",
        instructions: "Answer directly.",
        model: %{provider: :test, id: "model"},
        controls: %{
          inputs: [
            %{control: Jidoka.Controls.RequireContext, metadata: %{keys: [:tenant_id]}},
            %{control: Jidoka.Controls.MaxInputLength, metadata: %{max: 20}}
          ]
        }
      )

    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "allowed"}} end

    assert {:ok, %Turn.Result{content: "allowed"}} =
             Jidoka.turn(spec, Turn.Request.new!(input: "short input", context: %{"tenant_id" => "t1"}), llm: llm)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "require_context",
                boundary: :input,
                cause: {:missing_context_keys, ["tenant_id"]}
              }
            }} = Jidoka.turn(spec, "short input", llm: llm)

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "max_input_length",
                boundary: :input,
                cause: {:input_too_long, _length, 20}
              }
            }} =
             Jidoka.turn(
               spec,
               Turn.Request.new!(
                 input: "this input is definitely too long",
                 context: %{"tenant_id" => "t1"}
               ),
               llm: llm
             )
  end

  test "operation controls block before the operation capability runs" do
    llm = operation_llm("blocked")

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "operation_decision_control",
                boundary: :operation,
                operation: "controlled_lookup",
                cause: :blocked_operation
              }
            }} =
             OperationDecisionAgent.run_turn(
               operation_request("blocked", {:block, :blocked_operation}),
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    assert_receive {:operation_decision_control_called,
                    %{
                      arguments: %{"id" => "blocked"},
                      boundary: :operation,
                      control_name: "operation_decision_control",
                      idempotency: :idempotent,
                      idempotency_key?: true,
                      kind: :action,
                      operation: "controlled_lookup",
                      operation_kind: :action,
                      operation_match: %{kind: :action, name: "controlled_lookup"},
                      operation_spec: "controlled_lookup",
                      type: :control
                    }}

    refute_received {:controlled_lookup_called, "blocked"}
  end

  test "operation controls can interrupt into a review snapshot before execution" do
    assert {:hibernate, %Jidoka.Runtime.AgentSnapshot{} = snapshot} =
             OperationDecisionAgent.run_turn(
               operation_request("approval", {:interrupt, :approval_required}),
               llm: operation_llm("approval"),
               operation_context: %{test_pid: self()}
             )

    assert snapshot.cursor.phase == :review
    assert snapshot.turn_state.status == :waiting
    assert snapshot.turn_state.pending_interrupt.reason == :approval_required
    assert snapshot.turn_state.pending_interrupt.operation == "controlled_lookup"

    assert_receive {:operation_decision_control_called,
                    %{
                      arguments: %{"id" => "approval"},
                      kind: :action,
                      operation: "controlled_lookup"
                    }}

    refute_received {:controlled_lookup_called, "approval"}
  end

  test "operation controls reject invalid decisions before operation execution" do
    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :invalid_control_decision,
                control: "operation_decision_control",
                boundary: :operation,
                operation: "controlled_lookup",
                decision: :not_a_decision
              }
            }} =
             OperationDecisionAgent.run_turn(
               operation_request("invalid", :not_a_decision),
               llm: operation_llm("invalid"),
               operation_context: %{test_pid: self()}
             )

    assert_receive {:operation_decision_control_called,
                    %{
                      arguments: %{"id" => "invalid"},
                      kind: :action,
                      operation: "controlled_lookup"
                    }}

    refute_received {:controlled_lookup_called, "invalid"}
  end

  test "operation control exceptions are normalized as control failures" do
    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_failed,
                control: "operation_decision_control",
                boundary: :operation,
                operation: "controlled_lookup",
                cause: %RuntimeError{message: "operation control raised"}
              }
            }} =
             OperationDecisionAgent.run_turn(
               operation_request("raise", :raise),
               llm: operation_llm("raise"),
               operation_context: %{test_pid: self()}
             )

    assert_receive {:operation_decision_control_called,
                    %{
                      arguments: %{"id" => "raise"},
                      kind: :action,
                      operation: "controlled_lookup"
                    }}

    refute_received {:controlled_lookup_called, "raise"}
  end

  test "non-matching operation controls do not run" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "NonMatchingOperationControlAgent#{suffix}")

    Code.compile_string("""
    defmodule #{inspect(agent_module)} do
      use Jidoka.Agent

      agent :non_matching_operation_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      tools do
        action Jidoka.IntegrationSupport.ControlledLookupAction
      end

      controls do
        operation Jidoka.IntegrationSupport.OperationDecisionControl,
          when: [kind: :action, name: :other_lookup]
      end
    end
    """)

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 ->
          {:ok, %{type: :operation, name: "controlled_lookup", arguments: %{"id" => "nonmatch"}}}

        1 ->
          {:ok, %{type: :final, content: "nonmatch done"}}
      end
    end

    assert {:ok, %Turn.Result{content: "nonmatch done"}} =
             agent_module.run_turn(
               operation_request("nonmatch", {:block, :should_not_run}),
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    refute_received {:operation_decision_control_called, _}
    assert_received {:controlled_lookup_called, "nonmatch"}
  end

  test "operation controls also wrap data-defined local operations" do
    suffix = System.unique_integer([:positive])

    spec =
      Jidoka.agent!(
        id: "local_operation_control_agent_#{suffix}",
        instructions: "Use local_lookup before answering.",
        model: %{provider: :test, id: "model"},
        operations: [
          %{
            name: "local_lookup",
            description: "Looks up a local value.",
            idempotency: :pure
          }
        ],
        controls: %{
          operations: [
            %{
              control: Jidoka.IntegrationSupport.OperationDecisionControl,
              match: %{kind: :operation, name: "local_lookup"}
            }
          ]
        }
      )

    test_pid = self()

    operations =
      LocalOperations.operations(%{
        "local_lookup" => fn %{"id" => id}, _ctx ->
          send(test_pid, {:local_lookup_called, id})
          {:ok, %{id: id, value: "local-value"}}
        end
      })

    llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "local_lookup", arguments: %{"id" => "local"}}}
        1 -> {:ok, %{type: :final, content: "local done"}}
      end
    end

    assert {:ok, %Turn.Result{content: "local done"} = result} =
             Jidoka.turn(spec, operation_request("local", :cont),
               llm: llm,
               operations: operations
             )

    assert_receive {:operation_decision_control_called,
                    %{
                      arguments: %{"id" => "local"},
                      idempotency: :pure,
                      idempotency_key?: true,
                      kind: :operation,
                      operation: "local_lookup",
                      operation_kind: :operation,
                      operation_match: %{kind: :operation, name: "local_lookup"},
                      operation_spec: "local_lookup"
                    }}

    assert_receive {:local_lookup_called, "local"}

    timeline = timeline(result.events)
    control_index = operation_control_index(timeline, "operation_decision_control")
    capability_index = operation_capability_index(timeline, "local_lookup")

    assert is_integer(control_index)
    assert is_integer(capability_index)
    assert control_index < capability_index
  end

  test "operation controls support DSL metadata for built-in controls" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "OperationContextMetadataAgent#{suffix}")

    Code.compile_string("""
    defmodule #{inspect(agent_module)} do
      use Jidoka.Agent

      agent :operation_context_metadata_agent_#{suffix} do
        model %{provider: :test, id: "model"}
        instructions "Use controlled_lookup before answering."
      end

      tools do
        action Jidoka.IntegrationSupport.ControlledLookupAction
      end

      controls do
        operation Jidoka.Controls.RequireContext,
          when: [name: :controlled_lookup],
          metadata: %{keys: [:tenant_id]}
      end
    end
    """)

    assert [
             %Agent.Spec.Controls.Operation{
               control: Jidoka.Controls.RequireContext,
               metadata: %{keys: [:tenant_id]}
             }
           ] = agent_module.spec().controls.operations

    tenant_llm = fn _intent, %Effect.Journal{} = journal, _ctx ->
      case count_results(journal, :operation) do
        0 -> {:ok, %{type: :operation, name: "controlled_lookup", arguments: %{"id" => "tenant"}}}
        _count -> {:ok, %{type: :final, content: "tenant lookup done"}}
      end
    end

    assert {:ok, %Turn.Result{content: "tenant lookup done"}} =
             agent_module.run_turn(
               Turn.Request.new!(
                 input: "lookup tenant",
                 context: %{tenant_id: "tenant_1", test_pid: self()}
               ),
               llm: tenant_llm,
               operation_context: %{test_pid: self()}
             )

    assert_receive {:controlled_lookup_called, "tenant"}

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: "require_context",
                boundary: :operation,
                operation: "controlled_lookup",
                cause: {:missing_context_keys, ["tenant_id"]}
              }
            }} =
             agent_module.run_turn(
               Turn.Request.new!(input: "lookup missing", context: %{test_pid: self()}),
               llm: operation_llm("missing")
             )

    refute_received {:controlled_lookup_called, "missing"}
  end

  test "controls max_turns is enforced by the Runic turn runner" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "MaxTurnsControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.MaxTurnsControlAgent#{suffix} do
      use Jidoka.Agent

      agent :max_turns_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
        instructions "Always call controlled_lookup first."
      end

      tools do
        action Jidoka.IntegrationSupport.ControlledLookupAction
      end

      controls do
        max_turns 1
      end
    end
    """)

    llm = fn _intent, _journal, _ctx ->
      {:ok, %{type: :operation, name: "controlled_lookup", arguments: %{"id" => "max"}}}
    end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :turn,
              details: %{reason: :max_model_turns_exceeded, max_model_turns: 1}
            }} =
             agent_module.run_turn("lookup max",
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    assert_received {:controlled_lookup_called, "max"}
  end

  test "controls timeout is enforced before runtime effects are interpreted" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "TimeoutControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.TimeoutControlAgent#{suffix} do
      use Jidoka.Agent

      agent :timeout_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      controls do
        timeout 10
      end
    end
    """)

    counter = :counters.new(1, [])

    clock = fn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> 0
        _count -> 11
      end
    end

    llm = fn _intent, _journal, _ctx -> flunk("timed out turn must not call the LLM") end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :turn,
              details: %{
                reason: :turn_timeout_exceeded,
                timeout_ms: 10,
                elapsed_ms: 11
              }
            }} = agent_module.run_turn("hello", llm: llm, clock: clock)
  end

  test "output controls run before the final result leaves the turn" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "OutputControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.BlockOutputControl#{suffix} do
      use Jidoka.Control, name: "block_output_control_#{suffix}"

      @impl true
      def call(%{boundary: :output, result: result}) do
        if String.contains?(result, "blocked") do
          {:block, :blocked_output}
        else
          :cont
        end
      end
    end

    defmodule JidokaTest.OutputControlAgent#{suffix} do
      use Jidoka.Agent

      agent :output_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      controls do
        output JidokaTest.BlockOutputControl#{suffix}
      end
    end
    """)

    assert [
             %Agent.Spec.Controls.Output{control: result_control}
           ] = agent_module.spec().controls.outputs

    assert result_control.name() == "block_output_control_#{suffix}"
    control_name = "block_output_control_#{suffix}"

    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "blocked answer"}} end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: ^control_name,
                boundary: :output,
                cause: :blocked_output
              }
            }} = agent_module.run_turn("hello", llm: llm)
  end

  test "allowed output controls are traced before the turn is finished" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "AllowOutputControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.AllowOutputControl#{suffix} do
      use Jidoka.Control, name: "allow_output_control_#{suffix}"

      @impl true
      def call(%{boundary: :output, result: "allowed answer"}), do: :cont
    end

    defmodule JidokaTest.AllowOutputControlAgent#{suffix} do
      use Jidoka.Agent

      agent :allow_output_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      controls do
        output JidokaTest.AllowOutputControl#{suffix}
      end
    end
    """)

    llm = fn _intent, _journal, _ctx -> {:ok, %{type: :final, content: "allowed answer"}} end

    assert {:ok, %Turn.Result{} = result} = agent_module.run_turn("hello", llm: llm)

    assert [
             %{event: :control_allowed, data: %{boundary: :output}},
             %{event: :turn_finished}
           ] =
             result.events
             |> timeline()
             |> Enum.take(-2)
  end

  test "imported input controls and runtime controls normalize to DSL-equivalent spec data" do
    yaml = """
    agent:
      id: input_controlled_lookup_agent
      model:
        provider: test
        id: model
      instructions: Use controlled_lookup before answering controlled lookup questions.
    tools:
      actions:
        - controlled_lookup
    controls:
      max_turns: 3
      timeout: 1000
      inputs:
        - control: audit_input_control
        - control: block_input_control
    """

    assert {:ok, imported_spec} =
             Jidoka.import(yaml,
               format: :yaml,
               registries: registries()
             )

    assert semantic_projection(imported_spec) ==
             semantic_projection(InputControlledLookupAgent.spec())
  end

  if @live_enabled? do
    @tag :live
    @tag timeout: 120_000
    test "live ReqLLM turn runs controls before a real model tool loop" do
      suffix = System.unique_integer([:positive])
      agent_module = Module.concat(JidokaTest, "LiveControlsAgent#{suffix}")
      model = Jidoka.Config.model_ref(Jidoka.Config.default_model())

      Code.compile_string("""
      defmodule #{inspect(agent_module)} do
        use Jidoka.Agent

        agent :live_controls_agent_#{suffix} do
          model #{inspect(model)}

          instructions \"\"\"
          You are a Jidoka live controls integration test agent.
          You must call controlled_lookup exactly once before producing a final answer.
          Your final answer must include the exact canary value returned by controlled_lookup.
          \"\"\"
        end

        tools do
          action Jidoka.IntegrationSupport.ControlledLookupAction
        end

        controls do
          max_turns 4
          timeout 120_000
          input Jidoka.IntegrationSupport.AuditInputControl
          operation Jidoka.IntegrationSupport.ApprovalControl,
            when: [kind: :action, name: :controlled_lookup]
        end
      end
      """)

      request =
        Turn.Request.new!(
          input: "Look up ctrl_live with controlled_lookup.",
          metadata: %{test_pid: self()}
        )

      assert {:ok, %Turn.Result{} = result} =
               agent_module.run_turn(request, operation_context: %{test_pid: self()})

      assert_received {:input_control_called, "Look up ctrl_live with controlled_lookup."}

      assert_received {:operation_control_called, "require_approval", "controlled_lookup", %{"id" => "ctrl_live"}}

      assert_received {:controlled_lookup_called, "ctrl_live"}

      assert result.content =~ "jidoka_controls_live_canary_123"

      assert [%Effect.OperationResult{operation: "controlled_lookup"}] =
               result.agent_state.operation_results

      timeline = timeline(result.events)

      assert [
               %{event: :control_allowed, data: %{control: "audit_input_control"}}
               | _events
             ] = timeline

      operation_control_index = operation_control_index(timeline, "require_approval")
      capability_index = operation_capability_index(timeline, "controlled_lookup")

      assert is_integer(operation_control_index)
      assert is_integer(capability_index)
      assert operation_control_index < capability_index

      assert Enum.count(result.journal.results) == 3
    end
  else
    @tag :live
    @tag :skip
    test "live ReqLLM turn runs controls before a real model tool loop" do
      :ok
    end
  end

  test "same control can target different operation matches" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "MultiMatchControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.MultiMatchControl#{suffix} do
      use Jidoka.Control, name: "multi_match_control_#{suffix}"

      @impl true
      def call(_operation), do: :cont
    end

    defmodule JidokaTest.MultiMatchControlAgent#{suffix} do
      use Jidoka.Agent

      agent :multi_match_control_agent_#{suffix}

      controls do
        operation JidokaTest.MultiMatchControl#{suffix}, when: [kind: :action, name: :lookup]
        operation JidokaTest.MultiMatchControl#{suffix}, when: [kind: :action, name: :refund]
      end
    end
    """)

    assert [
             %Agent.Spec.Controls.Operation{match: %{kind: :action, name: "lookup"}},
             %Agent.Spec.Controls.Operation{match: %{kind: :action, name: "refund"}}
           ] = agent_module.spec().controls.operations
  end

  test "duplicate operation controls with the same match are rejected at DSL compile time" do
    suffix = System.unique_integer([:positive])

    assert_raise Spark.Error.DslError, ~r/duplicate_operation_control/, fn ->
      Code.compile_string("""
      defmodule JidokaTest.DuplicateOperationControl#{suffix} do
        use Jidoka.Control, name: "duplicate_operation_control_#{suffix}"

        @impl true
        def call(_operation), do: :cont
      end

      defmodule JidokaTest.DuplicateOperationControlAgent#{suffix} do
        use Jidoka.Agent

        agent :duplicate_operation_control_agent_#{suffix}

        controls do
          operation JidokaTest.DuplicateOperationControl#{suffix}, when: [kind: :action, name: :lookup]
          operation JidokaTest.DuplicateOperationControl#{suffix}, when: [kind: :action, name: :lookup]
        end
      end
      """)
    end
  end

  defp registries do
    %{
      actions: %{"controlled_lookup" => ControlledLookupAction},
      controls: %{
        "require_approval" => ApprovalControl,
        "audit_control" => AuditControl,
        "audit_input_control" => AuditInputControl,
        "block_input_control" => BlockInputControl
      }
    }
  end

  defp semantic_projection(spec) do
    spec
    |> Jidoka.project()
    |> Map.drop([:metadata])
  end

  defp operation_request(id, decision) do
    Turn.Request.new!(
      input: "Look up #{id}",
      context: %{test_pid: self()},
      metadata: %{
        test_pid: self(),
        operation_control_decision: decision
      }
    )
  end

  defp operation_llm(id) do
    fn _intent, _journal, _ctx ->
      {:ok, %{type: :operation, name: "controlled_lookup", arguments: %{"id" => id}}}
    end
  end
end
