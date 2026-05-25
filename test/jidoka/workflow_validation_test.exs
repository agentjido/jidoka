defmodule JidokaTest.WorkflowValidationTest do
  use JidokaTest.Support.Case, async: false

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "keeps workflow authoring separate from action-style using options" do
    module = Module.concat(JidokaTest.DynamicWorkflowDsl, "BadActionStyle#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      use Jidoka.Workflow,
        name: "bad_action_style",
        schema: Zoi.object(%{topic: Zoi.string()})
    end
    """

    assert_raise CompileError,
                 ~r/Jidoka.Workflow uses a Spark DSL.*workflow do/s,
                 fn -> Code.compile_string(source) end
  end

  test "requires workflow id" do
    assert_workflow_dsl_error(~r/workflow.id.*required/s, """
    workflow do
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2}, input: %{topic: input(:topic)}
    end

    output from(:normalize)
    """)
  end

  test "requires lower snake case workflow id" do
    assert_workflow_dsl_error(~r/workflow.id.*lower snake case/s, """
    workflow do
      id "Bad-ID"
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2}, input: %{topic: input(:topic)}
    end

    output from(:normalize)
    """)
  end

  test "requires a Zoi map input schema" do
    assert_workflow_dsl_error(~r/workflow.input.*required/s, """
    workflow do
      id :missing_input_workflow
    end

    steps do
      function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2}, input: %{}
    end

    output from(:normalize)
    """)

    assert_workflow_dsl_error(~r/workflow.input.*Zoi map\/object schema/s, """
    workflow do
      id :bad_input_workflow
      input Zoi.string()
    end

    steps do
      function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2}, input: %{}
    end

    output from(:normalize)
    """)
  end

  test "rejects duplicate step names" do
    assert_workflow_dsl_error(~r/step `same` is declared more than once/s, """
    workflow do
      id :duplicate_step_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action :same, JidokaTest.Workflow.AddAmount, input: %{value: input(:value)}
      action :same, JidokaTest.Workflow.DoubleValue, input: from(:same)
    end

    output from(:same)
    """)
  end

  test "rejects missing step refs" do
    assert_workflow_dsl_error(~r/references missing step `missing`/s, """
    workflow do
      id :missing_step_ref_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action :double, JidokaTest.Workflow.DoubleValue, input: from(:missing)
    end

    output from(:double)
    """)
  end

  test "rejects cyclic dependencies" do
    assert_workflow_dsl_error(~r/dependencies contain a cycle/s, """
    workflow do
      id :cyclic_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action :first, JidokaTest.Workflow.AddAmount, input: from(:second)
      action :second, JidokaTest.Workflow.DoubleValue, input: from(:first)
    end

    output from(:second)
    """)
  end

  test "rejects invalid output refs" do
    assert_workflow_dsl_error(~r/references missing step `missing`/s, """
    workflow do
      id :bad_output_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action :add, JidokaTest.Workflow.AddAmount, input: %{value: input(:value)}
    end

    output from(:missing)
    """)
  end

  test "rejects invalid static targets" do
    assert_workflow_dsl_error(~r/not a valid action-backed module/s, """
    workflow do
      id :bad_action_workflow
      input Zoi.object(%{value: Zoi.integer()})
    end

    steps do
      action :bad, String, input: %{value: input(:value)}
    end

    output from(:bad)
    """)

    assert_workflow_dsl_error(~r/function step target is not exported/s, """
    workflow do
      id :bad_function_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :bad, {JidokaTest.Workflow.Fns, :missing, 2}, input: %{topic: input(:topic)}
    end

    output from(:bad)
    """)

    assert_workflow_dsl_error(~r/not a Jidoka-compatible agent/s, """
    workflow do
      id :bad_agent_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      agent :bad, String, prompt: input(:topic)
    end

    output from(:bad)
    """)
  end

  test "rejects input refs that are not declared in the input schema" do
    assert_workflow_dsl_error(~r/input reference `missing` is not declared/s, """
    workflow do
      id :missing_input_ref_workflow
      input Zoi.object(%{topic: Zoi.string()})
    end

    steps do
      function :normalize, {JidokaTest.Workflow.Fns, :normalize, 2}, input: %{topic: input(:missing)}
    end

    output from(:normalize)
    """)
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
