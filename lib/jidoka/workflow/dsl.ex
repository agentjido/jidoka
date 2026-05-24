defmodule Jidoka.Workflow.Dsl do
  @moduledoc false

  alias Jidoka.Workflow.Dsl.{AgentStep, FunctionStep, ToolStep}

  @workflow_section %Spark.Dsl.Section{
    name: :workflow,
    describe: """
    Configure the immutable Jidoka workflow contract.
    """,
    schema: [
      id: [
        type: :any,
        required: false,
        doc: "The stable public workflow id. Must be lower snake case."
      ],
      description: [
        type: :string,
        required: false,
        doc: "Optional human-readable workflow description."
      ],
      input: [
        type: :any,
        required: false,
        doc: "Required Zoi map/object schema for workflow input."
      ]
    ]
  }

  @tool_step_entity %Spark.Dsl.Entity{
    name: :tool,
    describe: "Run a Jido Action-backed tool as a workflow step.",
    target: ToolStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :module, :input],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Unique lower snake case step name."
      ],
      module: [
        type: :atom,
        required: true,
        doc: "A `Jidoka.Action` or generic Jido Action-backed module."
      ],
      input: [
        type: :any,
        required: false,
        default: %{},
        doc: "Step input mapping using `input/1`, `from/1`, `from/2`, `context/1`, and `value/1` refs."
      ],
      after: [
        type: {:list, :atom},
        required: false,
        default: [],
        doc: "Optional control-only dependencies."
      ]
    ]
  }

  @function_step_entity %Spark.Dsl.Entity{
    name: :function,
    describe: "Run a deterministic `{module, function, 2}` workflow step.",
    target: FunctionStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :mfa, :input],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Unique lower snake case step name."
      ],
      mfa: [
        type: :any,
        required: true,
        doc: "A `{module, function, 2}` tuple called as `fun.(params, context)`."
      ],
      input: [
        type: :any,
        required: false,
        default: %{},
        doc: "Step input mapping using workflow refs."
      ],
      after: [
        type: {:list, :atom},
        required: false,
        default: [],
        doc: "Optional control-only dependencies."
      ]
    ]
  }

  @agent_step_entity %Spark.Dsl.Entity{
    name: :agent,
    describe: "Call a compiled Jidoka-compatible agent or runtime-provided imported agent.",
    target: AgentStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :agent, :context],
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Unique lower snake case step name."
      ],
      agent: [
        type: :any,
        required: true,
        doc: "A Jidoka-compatible agent module or `{:imported, key}` runtime agent reference."
      ],
      prompt: [
        type: :any,
        required: true,
        doc: "Prompt value or workflow ref."
      ],
      context: [
        type: :any,
        required: false,
        default: %{},
        doc: "Agent context mapping using workflow refs."
      ],
      after: [
        type: {:list, :atom},
        required: false,
        default: [],
        doc: "Optional control-only dependencies."
      ]
    ]
  }

  @steps_section %Spark.Dsl.Section{
    name: :steps,
    imports: [Jidoka.Workflow.Ref],
    describe: """
    Configure workflow steps.
    """,
    entities: [
      @tool_step_entity,
      @function_step_entity,
      @agent_step_entity
    ]
  }

  @output_section %Spark.Dsl.Section{
    name: :workflow_output,
    top_level?: true,
    imports: [Jidoka.Workflow.Ref],
    describe: """
    Configure workflow output selection.
    """,
    schema: [
      output: [
        type: :any,
        required: false,
        doc: "Workflow output selector, usually `from(:step)` or `from(:step, :field)`."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [
      @workflow_section,
      @steps_section,
      @output_section
    ]
end
