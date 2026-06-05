defmodule Jidoka.WorkflowDslTest do
  use ExUnit.Case, async: false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Effect
  alias Jidoka.Turn
  alias Jidoka.Operation.Source.Workflow, as: WorkflowSource
  alias Jidoka.Workflow
  alias Jidoka.Workflow.ParametersSchema
  alias Jidoka.Workflow.Runtime.StepRunner
  alias Jidoka.Workflow.Runtime.Value
  alias Jidoka.Workflow.{Ref, Spec, Step}

  import Jidoka.TestSupport, only: [count_results: 2]

  defmodule AddAmount do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_add_amount",
      description: "Adds a fixed amount to a workflow value.",
      schema:
        Zoi.object(%{
          value: Zoi.integer(),
          amount: Zoi.integer() |> Zoi.default(1)
        })

    @impl true
    def run(%{value: value, amount: amount}, _context), do: {:ok, %{value: value + amount}}
  end

  defmodule DoubleValue do
    @moduledoc false

    use Jidoka.Action,
      name: "workflow_double_value",
      description: "Doubles a workflow value.",
      schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{value: value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule Fns do
    @moduledoc false

    def normalize(%{topic: topic, suffix: suffix}, _context), do: {:ok, %{prompt: "#{topic}:#{suffix}"}}
    def raw(%{value: value}, _context), do: %{value: value}
    def error(%{reason: reason}, _context), do: {:error, reason}
    def raises(_params, _context), do: raise("workflow function raised")
    def throws(_params, _context), do: throw(:workflow_function_threw)

    def sleep(%{ms: ms}, _context) do
      Process.sleep(ms)
      {:ok, %{slept: ms}}
    end

    def wait_for_release(%{tag: tag}, context) do
      test_pid = Map.get(context, :test_pid, Map.get(context, "test_pid"))
      send(test_pid, {:workflow_step_started, tag, self()})

      receive do
        {:release_workflow_step, ^tag} -> {:ok, %{tag: tag}}
      after
        1_000 -> {:error, {:release_timeout, tag}}
      end
    end

    def collect_tags(%{left: left, right: right}, _context) do
      {:ok, %{tags: [left.tag, right.tag]}}
    end

    def pass_tag(%{tag: tag}, _context), do: {:ok, %{tag: tag}}
  end

  defmodule EchoAgent do
    @moduledoc false

    def run_turn(input, opts \\ []) do
      context = Keyword.get(opts, :context, %{})
      topic = Map.get(context, :topic, Map.get(context, "topic", "none"))
      {:ok, %{content: "echo:#{input}:topic=#{topic}"}}
    end
  end

  defmodule HibernateAgent do
    @moduledoc false

    def run_turn(_input, _opts), do: {:hibernate, %{reason: :review_required}}
  end

  defmodule ErrorAgent do
    @moduledoc false

    def run_turn(_input, _opts), do: {:error, :agent_failed}
  end

  defmodule InvalidResultAgent do
    @moduledoc false

    def run_turn(_input, _opts), do: :not_a_turn_result
  end

  defmodule InvalidToolAction do
    @moduledoc false

    def to_tool, do: %{function: fn _arguments, _context -> :not_a_tool_result end}
  end

  defmodule ToolErrorAction do
    @moduledoc false

    def to_tool, do: %{function: fn _arguments, _context -> {:error, "not-json"} end}
  end

  defmodule RawBinaryToolAction do
    @moduledoc false

    def to_tool, do: %{function: fn _arguments, _context -> {:ok, "not-json"} end}
  end

  defmodule AllowControl do
    @moduledoc false

    use Jidoka.Control, name: "allow_workflow"

    @impl true
    def call(_context), do: :cont
  end

  defmodule FunctionWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:function_workflow)
      description "Normalizes a topic with runtime context."
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {Fns, :normalize, 2},
        input: %{
          topic: input(:topic),
          suffix: context(:suffix)
        }
    end

    output from(:normalize, :prompt)
  end

  defmodule ActionWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:action_workflow)
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action(:add, AddAmount,
        input: %{
          value: input(:value),
          amount: value(1)
        }
      )

      action(:double, DoubleValue, input: from(:add))
    end

    output from(:double)
  end

  defmodule SlowWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:slow_workflow)
      input Zoi.object(%{ms: Zoi.integer()})
    end

    steps do
      function :sleep, {Fns, :sleep, 2}, input: %{ms: input(:ms)}
    end

    output from(:sleep)
  end

  defmodule ParallelWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:parallel_workflow)
      input Zoi.object(%{})
    end

    steps do
      function :left, {Fns, :wait_for_release, 2}, input: %{tag: value(:left)}
      function :right, {Fns, :wait_for_release, 2}, input: %{tag: value(:right)}

      function :collect, {Fns, :collect_tags, 2},
        input: %{
          left: from(:left),
          right: from(:right)
        }
    end

    output from(:collect)
  end

  defmodule DependentWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:dependent_workflow)
      input Zoi.object(%{})
    end

    steps do
      function :first, {Fns, :wait_for_release, 2}, input: %{tag: value(:first)}

      function :second, {Fns, :wait_for_release, 2},
        input: %{
          tag: value(:second),
          first: from(:first)
        }
    end

    output from(:second)
  end

  defmodule AgentWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:agent_workflow)
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :build_prompt, {Fns, :normalize, 2},
        input: %{
          topic: input(:topic),
          suffix: value("draft")
        }

      agent(:draft, EchoAgent,
        prompt: from(:build_prompt, :prompt),
        context: %{topic: input("topic")}
      )
    end

    output from(:draft)
  end

  defmodule CallbackWorkflow do
    @moduledoc false

    use Jidoka.Workflow,
      id: :callback_workflow,
      description: "Legacy callback workflow.",
      parameters_schema: %{"type" => "object"}

    @impl true
    def run(input, context), do: {:ok, %{input: input, context: context}}
  end

  defmodule PlainCallbackWorkflow do
    @moduledoc false

    def id, do: :plain_callback_workflow
    def description, do: ""
    def parameters_schema, do: %{"type" => "object"}
    def run(input, context), do: {:ok, {input, context}}
  end

  defmodule InvalidSpecWorkflow do
    @moduledoc false

    def __jidoka_workflow__, do: :not_a_spec
    def run(input, _context), do: {:ok, input}
  end

  defmodule NoRunWorkflow do
    @moduledoc false
  end

  defmodule WorkflowAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :workflow_dsl_agent do
      model %{provider: :test, id: "model"}
      instructions "Use run_workflow for deterministic arithmetic."
    end

    tools do
      workflow ActionWorkflow,
        as: :run_workflow,
        async: true,
        max_concurrency: 4,
        forward_context: {:only, [:suffix]},
        result: :structured
    end
  end

  defmodule UnsafeWorkflowAgent do
    @moduledoc false

    use Jidoka.Agent

    agent :unsafe_workflow_agent do
      model %{provider: :test, id: "model"}
      instructions "Use dangerous_workflow when requested."
    end

    controls do
      operation AllowControl, when: [kind: :workflow, name: "dangerous_workflow"]
    end

    tools do
      workflow ActionWorkflow,
        as: :dangerous_workflow,
        idempotency: :unsafe_once
    end
  end

  test "workflow refs are explicit data tuples" do
    assert Ref.input(:topic) == {:jidoka_workflow_ref, :input, :topic}
    assert Ref.from(:step) == {:jidoka_workflow_ref, :from, :step, nil}
    assert Ref.from(:step, :value) == {:jidoka_workflow_ref, :from, :step, [:value]}
    assert Ref.from(:step, [:nested, "value"]) == {:jidoka_workflow_ref, :from, :step, [:nested, "value"]}
    assert Ref.context(:tenant) == {:jidoka_workflow_ref, :context, :tenant}
    assert Ref.value(1) == {:jidoka_workflow_ref, :value, 1}

    assert Ref.ref?(Ref.input("topic"))
    refute Ref.ref?(:topic)
  end

  test "workflow spec and step structs parse through Zoi" do
    step = Step.new!(name: :normalize, kind: "function", target: {Fns, :normalize, 2})
    spec = Spec.new!(id: "typed_workflow", module: __MODULE__, mode: "dsl", steps: [step])

    assert {:ok, %Step{kind: :action}} = Step.new(name: :act, kind: :action, target: AddAmount)
    assert {:ok, %Spec{mode: :callback}} = Spec.new(id: "callback_contract", module: __MODULE__)
    assert [:function, :action, :agent] = Step.kinds()
    assert [:callback, :dsl] = Spec.modes()
    assert %Zoi.Types.Struct{} = Step.schema()
    assert %Zoi.Types.Struct{} = Spec.schema()
    assert step.kind == :function
    assert spec.mode == :dsl
    assert [%Step{name: :normalize}] = spec.steps
  end

  test "workflow parameter schemas project common Zoi input types" do
    schema =
      Zoi.object(%{
        text: Zoi.string(),
        count: Zoi.integer(),
        score: Zoi.float(),
        enabled: Zoi.boolean(),
        tag: Zoi.atom(),
        anything: Zoi.any(),
        values: Zoi.array(Zoi.number())
      })

    assert %{
             "type" => "object",
             "required" => required,
             "properties" => %{
               "text" => %{"type" => "string"},
               "count" => %{"type" => "integer"},
               "score" => %{"type" => "number"},
               "enabled" => %{"type" => "boolean"},
               "tag" => %{"type" => "string"},
               "anything" => %{},
               "values" => %{"type" => "array", "items" => %{"type" => "number"}}
             }
           } = ParametersSchema.from_zoi(schema)

    assert MapSet.new(required) ==
             MapSet.new(["text", "count", "score", "enabled", "tag", "anything", "values"])

    assert ParametersSchema.from_zoi(:not_a_schema) == nil
  end

  test "workflow value resolver normalizes atom and string keys recursively" do
    state = %{
      input: %{"topic" => "runic"},
      context: %{tenant: "northwind"},
      steps: %{lookup: %{"order" => %{id: "A1001"}}}
    }

    assert {:ok, "runic"} = Value.resolve(Ref.input(:topic), state)
    assert {:ok, "northwind"} = Value.resolve(Ref.context("tenant"), state)
    assert {:ok, "A1001"} = Value.resolve(Ref.from(:lookup, ["order", :id]), state)

    assert {:ok, %{refs: ["runic", "northwind"]}} =
             Value.resolve(%{refs: [Ref.input(:topic), Ref.context(:tenant)]}, state)

    assert {:ok, {"runic", "A1001"}} =
             Value.resolve({Ref.input(:topic), Ref.from(:lookup, [:order, "id"])}, state)

    assert {:error, {:missing_ref, :input, :missing}} = Value.resolve(Ref.input(:missing), state)
    assert Value.has_equivalent_key?(state.context, "tenant")
    refute Value.has_equivalent_key?(state.context, :missing)
  end

  test "DSL workflows compile into specs with derived parameters schema" do
    assert {:ok, %Spec{} = spec} = Workflow.definition(FunctionWorkflow)

    assert spec.id == "function_workflow"
    assert spec.mode == :dsl
    assert spec.parameters_schema["type"] == "object"
    assert spec.parameters_schema["required"] == ["topic"]
    assert [:normalize] = Enum.map(spec.steps, & &1.name)
    assert spec.context_refs == [:suffix]
  end

  test "inspection distinguishes workflow modules from agent turn plans" do
    assert %{
             kind: :workflow,
             workflow: %{
               id: "function_workflow",
               mode: :dsl,
               steps: [%{name: :normalize, kind: :function}]
             }
           } = Jidoka.inspect(FunctionWorkflow)
  end

  test "function workflows resolve input and context refs" do
    assert {:ok, "runic:ok"} =
             Workflow.run(FunctionWorkflow, %{"topic" => "runic"}, context: %{"suffix" => "ok"})
  end

  test "action workflows resolve from refs across ordered steps" do
    assert {:ok, %{"value" => 4}} = Workflow.run(ActionWorkflow, %{value: 1})
  end

  test "agent workflows run bounded agent steps and return text output" do
    assert {:ok, "echo:runic:draft:topic=runic"} = Workflow.run(AgentWorkflow, %{topic: "runic"})
  end

  test "callback workflow compatibility is preserved" do
    assert {:ok, %Spec{mode: :callback, id: "callback_workflow"}} = Workflow.definition(CallbackWorkflow)

    assert {:ok, %{input: %{value: 1}, context: %{tenant: "northwind"}}} =
             Workflow.run(CallbackWorkflow, [value: 1], context: %{tenant: "northwind"})
  end

  test "workflow module validation handles callback fallbacks and invalid modules" do
    assert {:ok, %Spec{mode: :callback, id: "plain_callback_workflow", description: nil}} =
             Workflow.definition(PlainCallbackWorkflow)

    assert {:ok, {%{value: 1}, %{tenant: "northwind"}}} =
             Workflow.run(PlainCallbackWorkflow, %{value: 1}, context: %{tenant: "northwind"})

    assert {:error, {:invalid_workflow_module, 123}} = Workflow.definition(123)

    assert {:error, {:invalid_workflow_module, InvalidSpecWorkflow, {:invalid_workflow_spec, :not_a_spec}}} =
             Workflow.definition(InvalidSpecWorkflow)

    assert_raise ArgumentError, ~r/invalid workflow/, fn ->
      Workflow.definition!(NoRunWorkflow)
    end

    assert {:ok, "workflow_dsl_test"} = Workflow.normalize_id(__MODULE__)
    assert {:error, {:invalid_workflow_id, nil}} = Workflow.normalize_id(nil)
  end

  test "workflow runtime rejects invalid input and runtime options" do
    assert {:error, error} = Workflow.run(ActionWorkflow, :bad_input)
    assert error.details.reason == :invalid_workflow_input

    assert {:error, error} = Workflow.run(ActionWorkflow, [:bad_input])
    assert error.details.reason == :invalid_workflow_input

    assert {:error, error} = Workflow.run(FunctionWorkflow, %{topic: 123}, context: %{suffix: "ok"})
    assert error.details.reason == :schema

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, context: :bad_context)
    assert error.details.reason == :invalid_workflow_context

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, context: [:bad_context])
    assert error.details.reason == :invalid_workflow_context

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, timeout: 0)
    assert error.details.reason == :invalid_workflow_timeout

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, async: :yes)
    assert error.details.reason == :invalid_workflow_async

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, max_concurrency: 0)
    assert error.details.reason == :invalid_workflow_max_concurrency

    assert {:error, error} = Workflow.run(ActionWorkflow, %{value: 1}, agent_opts: %{})
    assert error.details.reason == :invalid_workflow_agent_opts

    assert {:error, {:invalid_workflow_input, :bad_input}} = Workflow.run(CallbackWorkflow, :bad_input)
    assert {:error, {:invalid_workflow_input, [:bad_input]}} = Workflow.run(CallbackWorkflow, [:bad_input])

    assert {:error, {:invalid_workflow_context, :bad_context}} =
             Workflow.run(CallbackWorkflow, %{}, context: :bad_context)

    assert {:error, {:invalid_workflow_context, [:bad_context]}} =
             Workflow.run(CallbackWorkflow, %{}, context: [:bad_context])
  end

  test "workflow runtime enforces total wall-clock timeout" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, error} = Workflow.run(SlowWorkflow, %{ms: 100}, timeout: 10)

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 500
    assert Exception.message(error) =~ "timed out"
    assert error.details.workflow_id == "slow_workflow"
    assert error.details.reason == :timeout
    assert error.details.timeout == 10
  end

  test "workflow runtime can execute independent steps concurrently" do
    test_pid = self()

    task =
      Task.async(fn ->
        Workflow.run(ParallelWorkflow, %{},
          context: %{test_pid: test_pid},
          async: true,
          max_concurrency: 2,
          timeout: 2_000
        )
      end)

    assert_receive {:workflow_step_started, :left, left_pid}, 500
    assert_receive {:workflow_step_started, :right, right_pid}, 500

    send(left_pid, {:release_workflow_step, :left})
    send(right_pid, {:release_workflow_step, :right})

    assert {:ok, %{tags: [:left, :right]}} = Task.await(task, 2_000)
  end

  test "workflow runtime still gates dependent steps when async is enabled" do
    test_pid = self()

    task =
      Task.async(fn ->
        Workflow.run(DependentWorkflow, %{},
          context: %{test_pid: test_pid},
          async: true,
          max_concurrency: 2,
          timeout: 2_000
        )
      end)

    assert_receive {:workflow_step_started, :first, first_pid}, 500
    refute_receive {:workflow_step_started, :second, _second_pid}, 100

    send(first_pid, {:release_workflow_step, :first})

    assert_receive {:workflow_step_started, :second, second_pid}, 500
    send(second_pid, {:release_workflow_step, :second})

    assert {:ok, %{tag: :second}} = Task.await(task, 2_000)
  end

  test "workflow step runner exposes clear failure modes" do
    state = %{input: %{}, context: %{}, steps: %{}, agent_opts: [], error: nil}

    spec = Spec.new!(id: "step_runner_workflow", module: __MODULE__)

    assert %{error: :already_failed} =
             StepRunner.run_step(
               spec,
               %Step{name: :noop, kind: :function, target: {Fns, :raw, 2}},
               %{state | error: :already_failed}
             )

    assert {:error, {:unsupported_workflow_step, :unknown}} =
             StepRunner.execute_step(%Step{name: :unsupported, kind: :unknown, target: nil}, state)

    assert {:error, {:expected_map, :function_input, "not-a-map"}} =
             StepRunner.execute_step(
               %Step{
                 name: :bad_function_input,
                 kind: :function,
                 target: {Fns, :raw, 2},
                 input: Ref.value("not-a-map")
               },
               state
             )

    assert {:error, {:invalid_action_module, :not_an_action}} =
             StepRunner.execute_step(%Step{name: :bad_action, kind: :action, target: :not_an_action, input: %{}}, state)

    assert {:error, "not-json"} =
             StepRunner.execute_step(
               %Step{name: :tool_error, kind: :action, target: ToolErrorAction, input: %{}},
               state
             )

    assert {:ok, "not-json"} =
             StepRunner.execute_step(
               %Step{name: :raw_binary_tool, kind: :action, target: RawBinaryToolAction, input: %{}},
               state
             )

    assert {:error, {:invalid_action_result, :not_a_tool_result}} =
             StepRunner.execute_step(
               %Step{name: :invalid_tool, kind: :action, target: InvalidToolAction, input: %{}},
               state
             )

    assert {:error, {:expected_prompt, 123}} =
             StepRunner.execute_step(
               %Step{name: :bad_prompt, kind: :agent, target: EchoAgent, prompt: Ref.value(123)},
               state
             )

    assert {:error, {:agent_hibernated, %{reason: :review_required}}} =
             StepRunner.execute_step(
               %Step{name: :hibernate_agent, kind: :agent, target: HibernateAgent, prompt: "review", context: %{}},
               state
             )

    assert {:error, :agent_failed} =
             StepRunner.execute_step(
               %Step{name: :error_agent, kind: :agent, target: ErrorAgent, prompt: "fail", context: %{}},
               state
             )

    assert {:error, {:invalid_agent_result, :not_a_turn_result}} =
             StepRunner.execute_step(
               %Step{
                 name: :invalid_agent_result,
                 kind: :agent,
                 target: InvalidResultAgent,
                 prompt: "fail",
                 context: %{}
               },
               state
             )

    assert {:error, {:invalid_agent_module, :not_an_agent}} =
             StepRunner.execute_step(
               %Step{name: :invalid_agent, kind: :agent, target: :not_an_agent, prompt: "fail", context: %{}},
               state
             )
  end

  test "workflow operations compile and execute through the agent tool path" do
    assert [
             %Operation{
               name: "run_workflow",
               idempotency: :idempotent,
               metadata: %{
                 "source" => "workflow",
                 "kind" => "workflow",
                 "workflow" => "action_workflow",
                 "async" => true,
                 "max_concurrency" => 4,
                 "parameters_schema" => %{"required" => ["value"]}
               }
             } = operation
           ] = WorkflowAgent.spec().operations

    assert Operation.kind(operation) == :workflow

    llm = fn _intent, %Effect.Journal{} = journal ->
      case count_results(journal, :llm) do
        0 -> {:ok, %{type: :operation, name: "run_workflow", arguments: %{"value" => 5}}}
        1 -> {:ok, %{type: :final, content: "The deterministic result is 12."}}
      end
    end

    assert {:ok, %Turn.Result{} = result} =
             WorkflowAgent.run_turn("Run deterministic math.",
               llm: llm,
               operation_context: %{parent_context: %{suffix: "done"}}
             )

    assert [
             %Effect.OperationResult{
               operation: "run_workflow",
               output: %{
                 workflow: "action_workflow",
                 operation: "run_workflow",
                 output: %{"value" => 12}
               }
             }
           ] = result.agent_state.operation_results
  end

  test "workflow operation source supports output mode and validates options" do
    assert {:ok, source} =
             WorkflowSource.new(
               workflow: ActionWorkflow,
               as: "math_workflow",
               timeout: 1_000,
               async: true,
               max_concurrency: 2,
               forward_context: :none,
               result: "output",
               idempotency: "idempotent",
               metadata: nil
             )

    assert {:ok, [%Operation{name: "math_workflow", idempotency: :idempotent} = operation]} =
             WorkflowSource.operations(source, [])

    assert operation.metadata["result"] == "output"
    assert operation.metadata["async"] == true
    assert operation.metadata["max_concurrency"] == 2
    assert operation.metadata["parameters_schema"]["required"] == ["value"]

    assert {:ok, capability} =
             WorkflowSource.capability(source,
               context: %{parent_context: %{suffix: "hidden"}, agent_opts: [llm: fn _, _ -> :unused end]}
             )

    journal = Effect.Journal.new!()

    assert {:ok, %{"value" => 6}} =
             capability.(Effect.Intent.new(:operation, %{name: "math_workflow", arguments: %{"value" => 2}}), journal)

    assert {:error, {:missing_operation_handler, "wrong_workflow"}} =
             capability.(Effect.Intent.new(:operation, %{name: "wrong_workflow", arguments: %{}}), journal)

    assert {:error, {:unsupported_effect_kind, :llm}} =
             capability.(Effect.Intent.new(:llm, %{}), journal)

    assert {:error, {:invalid_workflow_module, "bad"}} = WorkflowSource.new(workflow: "bad")
    assert {:error, {:invalid_workflow_name, "Bad Name"}} = WorkflowSource.new(workflow: ActionWorkflow, as: "Bad Name")
    assert {:error, {:invalid_workflow_timeout, 0}} = WorkflowSource.new(workflow: ActionWorkflow, timeout: 0)
    assert {:error, {:invalid_workflow_async, :yes}} = WorkflowSource.new(workflow: ActionWorkflow, async: :yes)

    assert {:error, {:invalid_workflow_max_concurrency, 0}} =
             WorkflowSource.new(workflow: ActionWorkflow, max_concurrency: 0)

    assert {:error, {:invalid_workflow_forward_context, {:only, :tenant}}} =
             WorkflowSource.new(workflow: ActionWorkflow, forward_context: {:only, :tenant})

    assert {:error, {:invalid_workflow_result, "bad"}} = WorkflowSource.new(workflow: ActionWorkflow, result: "bad")

    assert {:error, {:invalid_workflow_idempotency, "bad"}} =
             WorkflowSource.new(workflow: ActionWorkflow, idempotency: "bad")

    assert {:error, {:invalid_workflow_metadata, :bad}} = WorkflowSource.new(workflow: ActionWorkflow, metadata: :bad)

    assert_raise ArgumentError, ~r/invalid workflow source/, fn ->
      WorkflowSource.new!(workflow: "bad")
    end
  end

  test "workflow operation source forwards and overrides context defensively" do
    assert {:ok, source} =
             WorkflowSource.new(
               workflow: FunctionWorkflow,
               as: :context_workflow,
               forward_context: {:only, [:suffix]},
               result: :output
             )

    assert {:ok, capability} =
             WorkflowSource.capability(source,
               context: [parent_context: [suffix: "parent", secret: "hidden"]]
             )

    journal = Effect.Journal.new!()

    assert {:ok, "runic:parent"} =
             capability.(
               Effect.Intent.new(:operation, %{name: "context_workflow", arguments: %{"topic" => "runic"}}),
               journal
             )

    assert {:ok, "runic:child"} =
             capability.(
               Effect.Intent.new(:operation, %{
                 name: "context_workflow",
                 arguments: %{"topic" => "runic", "context" => [suffix: "child"]}
               }),
               journal
             )

    assert {:ok, source} = WorkflowSource.new(workflow: ActionWorkflow, as: :math_workflow)
    assert {:ok, capability} = WorkflowSource.capability(source, context: :bad_context)

    assert {:ok, %{"value" => 4}} =
             capability.(
               Effect.Intent.new(:operation, %{name: "math_workflow", arguments: %{"value" => 1}}),
               journal
             )
  end

  test "workflow idempotency can opt into unsafe operation controls" do
    assert [
             %Operation{name: "dangerous_workflow", idempotency: :unsafe_once} = operation
           ] = UnsafeWorkflowAgent.spec().operations

    assert Operation.requires_control?(operation)
    assert {:ok, _plan} = Jidoka.plan(UnsafeWorkflowAgent.spec())
  end

  test "missing context refs fail with workflow context details" do
    assert {:error, error} = Workflow.run(FunctionWorkflow, %{topic: "runic"})

    assert Exception.message(error) =~ "Missing workflow context key"
    assert error.details.workflow_id == "function_workflow"
  end

  test "nested from refs fail clearly when the field is missing" do
    assert {:error, error} = Workflow.run(__MODULE__.FunctionWorkflowWithMissingField, %{value: 1})

    assert Exception.message(error) =~ "failed"
    assert error.details.step == :select_missing
    assert error.details.cause == {:missing_field, [:missing], %{value: 1}}
  end

  test "function step errors, raises, and throws are wrapped with step metadata" do
    assert {:error, error} = Workflow.run(__MODULE__.FunctionErrorWorkflow, %{reason: "nope"})
    assert error.details.step == :fail
    assert error.details.cause == "nope"

    assert {:error, error} = Workflow.run(__MODULE__.FunctionRaiseWorkflow, %{})
    assert error.details.step == :raise_step
    assert %RuntimeError{message: "workflow function raised"} = error.details.cause

    assert {:error, error} = Workflow.run(__MODULE__.FunctionThrowWorkflow, %{})
    assert error.details.step == :throw_step
    assert error.details.cause == {:throw, :workflow_function_threw}
  end

  test "DSL validation rejects invalid declarations" do
    assert_workflow_dsl_error(~r/workflow.id.*lower snake case/s, """
    workflow do
      id "Bad-ID"
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {Jidoka.WorkflowDslTest.Fns, :normalize, 2}, input: %{topic: input(:topic)}
    end

    output from(:normalize)
    """)

    assert_workflow_dsl_error(~r/step `same` is declared more than once/s, """
    workflow do
      id :duplicate_step_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :same, {Jidoka.WorkflowDslTest.Fns, :raw, 2}, input: %{value: input(:value)}
      function :same, {Jidoka.WorkflowDslTest.Fns, :raw, 2}, input: %{value: input(:value)}
    end

    output from(:same)
    """)

    assert_workflow_dsl_error(~r/references missing step `missing`/s, """
    workflow do
      id :missing_ref_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :double, {Jidoka.WorkflowDslTest.Fns, :raw, 2}, input: from(:missing)
    end

    output from(:double)
    """)

    assert_workflow_dsl_error(~r/dependencies contain a cycle/s, """
    workflow do
      id :cycle_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :first, {Jidoka.WorkflowDslTest.Fns, :raw, 2}, input: from(:second)
      function :second, {Jidoka.WorkflowDslTest.Fns, :raw, 2}, input: from(:first)
    end

    output from(:second)
    """)

    assert_workflow_dsl_error(~r/input reference `missing` is not declared/s, """
    workflow do
      id :missing_input_ref_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {Jidoka.WorkflowDslTest.Fns, :normalize, 2}, input: %{topic: input(:missing)}
    end

    output from(:normalize)
    """)

    assert_workflow_dsl_error(~r/output must reference at least one step/s, """
    workflow do
      id :static_output_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {Jidoka.WorkflowDslTest.Fns, :normalize, 2}, input: %{topic: input(:topic)}
    end

    output value("static")
    """)

    assert_workflow_dsl_error(~r/cannot mix callback options/s, """
    use Jidoka.Workflow, id: :mixed_workflow

    workflow do
      id :mixed_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {Jidoka.WorkflowDslTest.Fns, :normalize, 2}, input: %{topic: input(:topic)}
    end

    output from(:normalize)
    """)
  end

  defmodule FunctionWorkflowWithMissingField do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:missing_field_workflow)
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      function :source, {Fns, :raw, 2}, input: %{value: input(:value)}
      function :select_missing, {Fns, :raw, 2}, input: %{value: from(:source, :missing)}
    end

    output from(:select_missing)
  end

  defmodule FunctionErrorWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:function_error_workflow)
      input Zoi.object(%{reason: Zoi.string()})
    end

    steps do
      function :fail, {Fns, :error, 2}, input: %{reason: input(:reason)}
    end

    output from(:fail)
  end

  defmodule FunctionRaiseWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:function_raise_workflow)
      input Zoi.object(%{})
    end

    steps do
      function :raise_step, {Fns, :raises, 2}, input: %{}
    end

    output from(:raise_step)
  end

  defmodule FunctionThrowWorkflow do
    @moduledoc false

    use Jidoka.Workflow

    workflow do
      id(:function_throw_workflow)
      input Zoi.object(%{})
    end

    steps do
      function :throw_step, {Fns, :throws, 2}, input: %{}
    end

    output from(:throw_step)
  end

  defp assert_workflow_dsl_error(pattern, body) do
    module = Module.concat(JidokaTest.DynamicWorkflowDsl, "Workflow#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Workflow

      #{body}
    end
    """

    assert_raise Spark.Error.DslError, pattern, fn ->
      Code.compile_string(source)
    end
  end
end
