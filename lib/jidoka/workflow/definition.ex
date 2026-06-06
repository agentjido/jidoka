defmodule Jidoka.Workflow.Definition do
  @moduledoc false

  alias Jidoka.Workflow
  alias Jidoka.Workflow.Definition.{Graph, Refs, Steps, Validation}
  alias Jidoka.Workflow.Spec

  @spec build!(Macro.Env.t(), keyword()) :: Spec.t()
  def build!(%Macro.Env{} = env, opts \\ []) do
    owner_module = env.module
    Validation.ensure_callback_opts_absent!(owner_module, opts)

    configured_id = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :id)
    id = Validation.resolve_id!(owner_module, configured_id)
    description = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :description)
    metadata = Spark.Dsl.Extension.get_opt(owner_module, [:workflow], :metadata, %{})

    input_schema =
      owner_module
      |> Spark.Dsl.Extension.get_opt([:workflow], :input)
      |> Validation.resolve_input_schema!(owner_module)

    steps =
      owner_module
      |> Spark.Dsl.Extension.get_entities([:steps])
      |> Steps.normalize!(owner_module)

    output =
      owner_module
      |> Spark.Dsl.Extension.get_opt([:workflow_output], :output)
      |> Validation.require_output!(owner_module)

    Validation.validate_no_special_refs!(owner_module, [:workflow_output, :output], output)

    refs = Refs.collect([steps, output])
    output_refs = Refs.collect(output).from

    Validation.validate_input_refs!(owner_module, input_schema, refs.input)
    Validation.validate_output_refs!(owner_module, output_refs, output)

    dependencies = Graph.infer_dependencies(steps)
    Validation.validate_step_refs!(owner_module, steps, dependencies, refs.from)
    sorted_steps = Validation.sort_steps!(owner_module, steps, dependencies)

    Spec.new!(
      id: id,
      module: owner_module,
      description: description,
      mode: :dsl,
      input_schema: input_schema,
      parameters_schema: Workflow.ParametersSchema.from_zoi(input_schema),
      steps: sorted_steps,
      dependencies: dependencies,
      output: output,
      input_refs: Enum.sort_by(refs.input, &to_string/1),
      context_refs: Enum.sort_by(refs.context, &to_string/1),
      metadata: metadata || %{}
    )
  end
end
