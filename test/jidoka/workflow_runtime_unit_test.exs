defmodule JidokaTest.WorkflowRuntimeUnitTest do
  use ExUnit.Case, async: true

  alias Jidoka.Workflow.Runtime.{StepRunner, Value}
  alias Jidoka.Workflow.Ref

  defmodule FunctionSteps do
    def ok(params, context), do: {:ok, Map.put(params, :ctx, context.suffix)}
    def raw(params, _context), do: Map.put(params, :raw, true)
    def error(_params, _context), do: {:error, RuntimeError.exception("function exploded")}
    def raises(_params, _context), do: raise("raised function")
    def throws(_params, _context), do: throw(:thrown_function)
  end

  defmodule RaisingAgent do
    defmodule Runtime do
      use Jido.Agent,
        name: "workflow_raising_agent_runtime",
        schema: Zoi.object(%{})
    end

    def start_link(opts \\ []), do: Jidoka.start_agent(Runtime, opts)
    def chat(_pid, _message, _opts \\ []), do: raise("agent chat raised")
  end

  @state %{
    input: %{:topic => "schemas", "count" => 2},
    context: %{:suffix => "done", "tenant" => "acme"},
    agents: %{reviewer: :agent},
    steps: %{
      :draft => %{text: "hello", nested: %{score: 0.9}},
      "review" => %{accepted: true}
    },
    workflow_id: "unit_workflow",
    timeout: 10
  }

  test "extracts workflow state facts from direct, wrapped, and production inputs" do
    wrapped = %{Jidoka.Workflow.Runtime.Keys.state_key() => @state}

    assert Value.extract_state!(wrapped) == @state
    assert Value.extract_state!(%{input: wrapped}) == @state

    merged =
      Value.extract_state!(%{
        input: [
          %{Jidoka.Workflow.Runtime.Keys.state_key() => @state},
          %{Jidoka.Workflow.Runtime.Keys.state_key() => %{@state | steps: %{final: %{ok: true}}}}
        ]
      })

    assert merged.steps.draft == @state.steps.draft
    assert merged.steps.final == %{ok: true}

    assert_raise ArgumentError, ~r/expected Jidoka workflow state fact/, fn ->
      Value.extract_state!(:bad)
    end
  end

  test "resolves workflow refs inside nested maps, lists, and tuples" do
    value = %{
      topic: {:jidoka_workflow_ref, :input, :topic},
      tenant: {:jidoka_workflow_ref, :context, "tenant"},
      score: {:jidoka_workflow_ref, :from, :draft, [:nested, :score]},
      tuple: {{:jidoka_workflow_ref, :from, "review", [:accepted]}, {:jidoka_workflow_ref, :value, :static}},
      list: [{:jidoka_workflow_ref, :input, "count"}]
    }

    assert {:ok,
            %{
              topic: "schemas",
              tenant: "acme",
              score: 0.9,
              tuple: {true, :static},
              list: [2]
            }} = Value.resolve_value(value, @state)
  end

  test "workflow ref helpers build and recognize data wiring references" do
    assert Ref.input(:topic) == {:jidoka_workflow_ref, :input, :topic}
    assert Ref.context("tenant") == {:jidoka_workflow_ref, :context, "tenant"}
    assert Ref.from(:draft) == {:jidoka_workflow_ref, :from, :draft, nil}
    assert Ref.from(:draft, :text) == {:jidoka_workflow_ref, :from, :draft, [:text]}
    assert Ref.from(:draft, ["nested", :score]) == {:jidoka_workflow_ref, :from, :draft, ["nested", :score]}
    assert Ref.value(%{static: true}) == {:jidoka_workflow_ref, :value, %{static: true}}

    assert Ref.ref?(Ref.input(:topic))
    assert Ref.ref?(Ref.from(:draft, [:text]))
    refute Ref.ref?({:jidoka_workflow_ref, :from, "draft", nil})
    refute Ref.ref?(:not_a_ref)
  end

  test "returns structured missing ref and missing field errors" do
    assert Value.fetch_equivalent(%{"topic" => "schemas"}, :topic) == {:ok, "schemas"}
    assert Value.fetch_equivalent(%{topic: "schemas"}, "topic") == {:ok, "schemas"}
    assert Value.fetch_equivalent(%{}, :topic) == :error
    refute Value.has_equivalent_key?(%{}, :topic)

    assert {:error, {:missing_ref, :context, :missing}} =
             Value.resolve_value({:jidoka_workflow_ref, :context, :missing}, @state)

    assert {:error, {:missing_field, [:missing], %{text: "hello", nested: %{score: 0.9}}}} =
             Value.resolve_value({:jidoka_workflow_ref, :from, :draft, [:missing]}, @state)

    assert {:error, {:missing_field, [:nested], "hello"}} =
             Value.resolve_value({:jidoka_workflow_ref, :from, :draft, [:text, :nested]}, @state)
  end

  test "selects the final state that can resolve the workflow output" do
    definition = %{output: {:jidoka_workflow_ref, :from, :final, [:answer]}}

    partial = %{@state | steps: %{draft: %{text: "hello"}}}
    complete = %{@state | steps: %{final: %{answer: 42}}}

    assert Value.select_final_state(definition, [
             %{Jidoka.Workflow.Runtime.Keys.state_key() => partial},
             %{Jidoka.Workflow.Runtime.Keys.state_key() => complete}
           ]) == complete

    fallback_definition = %{output: {:jidoka_workflow_ref, :from, :missing, nil}}
    assert Value.select_final_state(fallback_definition, [partial, complete]) == complete
  end

  test "function steps normalize ok, raw, error, rescue, and throw outcomes" do
    definition = %{id: "unit_workflow"}
    state = %{@state | context: %{suffix: "done"}}

    ok_step = %{kind: :function, target: {FunctionSteps, :ok, 2}, input: %{value: 1}}
    assert StepRunner.execute_step(definition, ok_step, state) == {:ok, %{value: 1, ctx: "done"}}

    raw_step = %{kind: :function, target: {FunctionSteps, :raw, 2}, input: %{value: 1}}
    assert StepRunner.execute_step(definition, raw_step, state) == {:ok, %{value: 1, raw: true}}

    error_step = %{kind: :function, target: {FunctionSteps, :error, 2}, input: %{}}
    assert StepRunner.execute_step(definition, error_step, state) == {:error, "function exploded"}

    raise_step = %{kind: :function, target: {FunctionSteps, :raises, 2}, input: %{}}
    assert {:error, %RuntimeError{message: "raised function"}} = StepRunner.execute_step(definition, raise_step, state)

    throw_step = %{kind: :function, target: {FunctionSteps, :throws, 2}, input: %{}}
    assert StepRunner.execute_step(definition, throw_step, state) == {:error, {:throw, :thrown_function}}
  end

  test "step runner validates resolved action, function, and agent inputs" do
    definition = %{id: "unit_workflow"}

    assert {:error, {:expected_map, :action_input, "bad"}} =
             StepRunner.execute_step(
               definition,
               %{kind: :action, target: JidokaTest.Workflow.AddAmount, input: "bad"},
               @state
             )

    assert {:error, {:expected_map, :function_input, "bad"}} =
             StepRunner.execute_step(
               definition,
               %{kind: :function, target: {FunctionSteps, :ok, 2}, input: "bad"},
               @state
             )

    assert {:error, {:expected_prompt, 123}} =
             StepRunner.execute_step(
               definition,
               %{kind: :agent, target: __MODULE__, prompt: 123, context: %{}},
               @state
             )

    assert {:error, {:expected_map, :agent_context, "bad"}} =
             StepRunner.execute_step(
               definition,
               %{kind: :agent, target: __MODULE__, prompt: "hello", context: "bad"},
               @state
             )

    assert {:error, {:missing_imported_agent, :writer}} =
             StepRunner.execute_step(
               definition,
               %{kind: :agent, target: {:imported, :writer}, prompt: "hello", context: %{}},
               @state
             )

    assert {:error, {:invalid_agent_target, {:bad, :target}}} =
             StepRunner.execute_step(
               definition,
               %{kind: :agent, target: {:bad, :target}, prompt: "hello", context: %{}},
               @state
             )
  end

  test "agent steps normalize raised chat failures without crashing the caller" do
    definition = %{id: "unit_workflow"}
    state = %{@state | timeout: 1_000}

    assert {:error, %RuntimeError{message: "agent chat raised"}} =
             StepRunner.execute_step(
               definition,
               %{kind: :agent, target: RaisingAgent, prompt: "hello", context: %{}},
               state
             )
  end

  test "step errors include workflow and step metadata" do
    error =
      StepRunner.step_error(
        %{id: "unit_workflow"},
        %{name: :draft, kind: :function, target: {FunctionSteps, :ok, 2}},
        :boom
      )

    assert %Jidoka.Error.ExecutionError{} = error
    assert error.phase == :workflow_step
    assert error.details.workflow_id == "unit_workflow"
    assert error.details.step == :draft
    assert error.details.cause == :boom
  end
end
