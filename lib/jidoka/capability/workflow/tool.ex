defmodule Jidoka.Workflow.Capability.Tool do
  @moduledoc false

  @output_schema Zoi.object(%{output: Zoi.any()})
  @structured_output_schema Zoi.object(%{output: Zoi.any(), workflow: Zoi.map()})

  @doc false
  @spec input_schema(map()) :: Zoi.schema()
  def input_schema(%{workflow: workflow}) do
    {:ok, definition} = Jidoka.Workflow.definition(workflow)
    definition.input_schema
  end

  @doc false
  @spec output_schema(map()) :: Zoi.schema()
  def output_schema(%{result: :structured}), do: @structured_output_schema
  def output_schema(%{}), do: @output_schema

  @doc false
  @spec tool_module(base_module :: module(), map(), non_neg_integer()) :: module()
  def tool_module(base_module, %{name: name}, index) do
    suffix =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> Macro.camelize()

    Module.concat(base_module, :"WorkflowTool#{suffix}#{index}")
  end

  @doc false
  @spec tool_module_ast(module(), map()) :: Macro.t()
  def tool_module_ast(tool_module, %{name: name, description: description} = workflow) do
    quote location: :keep do
      defmodule unquote(tool_module) do
        use Jidoka.Action,
          name: unquote(name),
          description: unquote(description),
          schema: unquote(Macro.escape(Jidoka.Workflow.Capability.Tool.input_schema(workflow))),
          output_schema: unquote(Macro.escape(Jidoka.Workflow.Capability.Tool.output_schema(workflow)))

        @workflow unquote(Macro.escape(workflow))

        @impl true
        def run(params, context) do
          Jidoka.Workflow.Capability.Runtime.run_workflow_tool(@workflow, params, context)
        end
      end
    end
  end
end
