defmodule Jidoka.Subagent.Tool do
  @moduledoc false

  @task_schema Zoi.object(%{task: Zoi.string()})
  @text_output_schema Zoi.object(%{result: Zoi.string()})
  @structured_output_schema Zoi.object(%{result: Zoi.any(), subagent: Zoi.map()})

  @spec task_schema() :: Zoi.schema()
  def task_schema, do: @task_schema

  @spec output_schema(map()) :: Zoi.schema()
  def output_schema(%{result: :structured}), do: @structured_output_schema
  def output_schema(%{}), do: @text_output_schema

  @spec tool_module(base_module :: module(), map(), non_neg_integer()) :: module()
  def tool_module(base_module, %{name: name}, index) do
    suffix =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> Macro.camelize()

    Module.concat(base_module, :"SubagentTool#{suffix}#{index}")
  end

  @spec tool_module_ast(module(), map()) :: Macro.t()
  def tool_module_ast(tool_module, %{name: name, description: description} = subagent) do
    quote location: :keep do
      defmodule unquote(tool_module) do
        use Jidoka.Action,
          name: unquote(name),
          description: unquote(description),
          schema: unquote(Macro.escape(Jidoka.Subagent.Tool.task_schema())),
          output_schema: unquote(Macro.escape(Jidoka.Subagent.Tool.output_schema(subagent)))

        @subagent unquote(Macro.escape(subagent))

        @impl true
        def run(params, context) do
          Jidoka.Subagent.Runtime.run_subagent_tool(@subagent, params, context)
        end
      end
    end
  end
end
