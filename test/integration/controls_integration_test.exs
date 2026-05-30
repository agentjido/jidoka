defmodule Jidoka.ControlsIntegrationTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent
  alias Jidoka.Config
  alias Jidoka.Effect
  alias Jidoka.IntegrationSupport.ApprovalControl
  alias Jidoka.IntegrationSupport.AuditControl
  alias Jidoka.IntegrationSupport.AuditInputControl
  alias Jidoka.IntegrationSupport.BlockInputControl
  alias Jidoka.IntegrationSupport.ControlledLookupAction
  alias Jidoka.IntegrationSupport.ControlledLookupAgent
  alias Jidoka.IntegrationSupport.InputControlledLookupAgent
  alias Jidoka.Turn

  @live_enabled? not is_nil(
                   System.get_env("OPENAI_API_KEY") || System.get_env("ANTHROPIC_API_KEY")
                 )

  test "operation controls compile into spec data and do not execute in the current runtime slice" do
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
           } = Jidoka.projection(spec)

    llm = fn _intent, %Effect.Journal{} = journal ->
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

    assert {:ok, %Turn.Result{} = result} =
             ControlledLookupAgent.run_turn("Look up ctrl_123",
               llm: llm,
               operation_context: %{test_pid: self()}
             )

    assert result.content == "Controlled lookup ctrl_123 is controlled-value."
    assert_received {:controlled_lookup_called, "ctrl_123"}
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

    llm = fn _intent, _journal ->
      assert_received {:input_control_called, "allowed lookup"}
      {:ok, %{type: :final, content: "allowed"}}
    end

    request =
      Turn.Request.new!(
        input: "allowed lookup",
        context: %{test_pid: self()}
      )

    assert {:ok, %Turn.Result{content: "allowed"} = result} =
             InputControlledLookupAgent.run_turn(request, llm: llm)

    assert [
             %{event: :control_allowed, data: %{control: "audit_input_control"}},
             %{event: :control_allowed, data: %{control: "block_input_control"}}
             | _events
           ] = Jidoka.Extensions.Trace.timeline(result.events)
  end

  test "input controls block the turn before LLM or operation effects run" do
    llm = fn _intent, _journal -> flunk("blocked input must not call the LLM") end

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

    llm = fn _intent, _journal ->
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

    llm = fn _intent, _journal -> flunk("timed out turn must not call the LLM") end

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

  test "result controls run before the final result leaves the turn" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "ResultControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.BlockResultControl#{suffix} do
      use Jidoka.Control, name: "block_result_control_#{suffix}"

      @impl true
      def call(%{boundary: :result, result: result}) do
        if String.contains?(result, "blocked") do
          {:block, :blocked_result}
        else
          :cont
        end
      end
    end

    defmodule JidokaTest.ResultControlAgent#{suffix} do
      use Jidoka.Agent

      agent :result_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      controls do
        result JidokaTest.BlockResultControl#{suffix}
      end
    end
    """)

    assert [
             %Agent.Spec.Controls.Result{control: result_control}
           ] = agent_module.spec().controls.results

    assert result_control.name() == "block_result_control_#{suffix}"
    control_name = "block_result_control_#{suffix}"

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "blocked answer"}} end

    assert {:error,
            %Jidoka.Error.ExecutionError{
              phase: :control,
              details: %{
                reason: :control_blocked,
                control: ^control_name,
                boundary: :result,
                cause: :blocked_result
              }
            }} = agent_module.run_turn("hello", llm: llm)
  end

  test "allowed result controls are traced before the turn is finished" do
    suffix = System.unique_integer([:positive])
    agent_module = Module.concat(JidokaTest, "AllowResultControlAgent#{suffix}")

    Code.compile_string("""
    defmodule JidokaTest.AllowResultControl#{suffix} do
      use Jidoka.Control, name: "allow_result_control_#{suffix}"

      @impl true
      def call(%{boundary: :result, result: "allowed answer"}), do: :cont
    end

    defmodule JidokaTest.AllowResultControlAgent#{suffix} do
      use Jidoka.Agent

      agent :allow_result_control_agent_#{suffix} do
        model %{provider: :test, id: "model"}
      end

      controls do
        result JidokaTest.AllowResultControl#{suffix}
      end
    end
    """)

    llm = fn _intent, _journal -> {:ok, %{type: :final, content: "allowed answer"}} end

    assert {:ok, %Turn.Result{} = result} = agent_module.run_turn("hello", llm: llm)

    assert [
             %{event: :control_allowed, data: %{boundary: :result}},
             %{event: :turn_finished}
           ] =
             result.events
             |> Jidoka.Extensions.Trace.timeline()
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
    test "live ReqLLM turn runs input controls before a real model tool loop" do
      suffix = System.unique_integer([:positive])
      agent_module = Module.concat(JidokaTest, "LiveControlsAgent#{suffix}")
      model = live_model_spec()

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
      assert_received {:controlled_lookup_called, "ctrl_live"}

      assert result.content =~ "jidoka_controls_live_canary_123"

      assert [%Effect.OperationResult{operation: "controlled_lookup"}] =
               result.agent_state.operation_results

      assert [
               %{event: :control_allowed, data: %{control: "audit_input_control"}}
               | _events
             ] = Jidoka.Extensions.Trace.timeline(result.events)

      assert Enum.count(result.journal.results) == 3
    end
  else
    @tag :live
    @tag :skip
    test "live ReqLLM turn runs input controls before a real model tool loop" do
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
    |> Jidoka.projection()
    |> Map.drop([:metadata])
  end

  defp count_results(%Effect.Journal{results: results}, kind) do
    results
    |> Map.values()
    |> Enum.count(&(&1.kind == kind))
  end

  defp live_model_spec do
    model =
      System.get_env("JIDOKA_DEFAULT_MODEL") ||
        System.get_env("JIDOKA_LIVE_MODEL") ||
        Config.default_model()

    case model do
      %LLMDB.Model{} -> Config.model_ref(model)
      model -> model
    end
  end
end
