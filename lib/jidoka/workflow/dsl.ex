defmodule Jidoka.Workflow.Dsl do
  @moduledoc false

  alias Jidoka.Workflow.Dsl.{ActionStep, AgentStep, FunctionStep}

  @workflow_section %Spark.Dsl.Section{
    name: :workflow,
    describe: "Configure the immutable Jidoka workflow contract.",
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
      ],
      metadata: [
        type: :map,
        required: false,
        default: %{},
        doc: "Optional workflow metadata."
      ]
    ]
  }

  @action_step_entity %Spark.Dsl.Entity{
    name: :action,
    target: ActionStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :module, :input],
    describe: "Run a Jido/Jidoka action module as a workflow step.",
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Unique lower snake case step name."
      ],
      module: [
        type: :atom,
        required: true,
        doc: "A module exposing a Jido tool via `to_tool/0`."
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
      ],
      metadata: [
        type: :map,
        required: false,
        default: %{},
        doc: "Optional step metadata."
      ]
    ]
  }

  @function_step_entity %Spark.Dsl.Entity{
    name: :function,
    target: FunctionStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :mfa, :input],
    describe: "Run a deterministic `{module, function, 2}` workflow step.",
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
      ],
      metadata: [
        type: :map,
        required: false,
        default: %{},
        doc: "Optional step metadata."
      ]
    ]
  }

  @agent_step_entity %Spark.Dsl.Entity{
    name: :agent,
    target: AgentStep,
    imports: [Jidoka.Workflow.Ref],
    args: [:name, :agent],
    describe: "Call a bounded Jidoka-compatible agent as a workflow step.",
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "Unique lower snake case step name."
      ],
      agent: [
        type: :atom,
        required: true,
        doc: "A Jidoka-compatible agent module."
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
      ],
      metadata: [
        type: :map,
        required: false,
        default: %{},
        doc: "Optional step metadata."
      ]
    ]
  }

  @steps_section %Spark.Dsl.Section{
    name: :steps,
    imports: [Jidoka.Workflow.Ref],
    describe: "Configure workflow steps.",
    entities: [
      @action_step_entity,
      @function_step_entity,
      @agent_step_entity
    ]
  }

  @output_section %Spark.Dsl.Section{
    name: :workflow_output,
    top_level?: true,
    imports: [Jidoka.Workflow.Ref],
    describe: "Configure workflow output selection.",
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
