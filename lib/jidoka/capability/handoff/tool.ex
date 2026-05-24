defmodule Jidoka.Handoff.Tool do
  @moduledoc false

  @input_schema Zoi.object(%{
                  message: Zoi.string() |> Zoi.trim() |> Zoi.min(1),
                  summary: Zoi.string() |> Zoi.trim() |> Zoi.min(1) |> Zoi.optional(),
                  reason: Zoi.string() |> Zoi.trim() |> Zoi.min(1) |> Zoi.optional()
                })
  @output_schema Zoi.object(%{handoff: Zoi.map()})

  @doc false
  @spec input_schema() :: Zoi.schema()
  def input_schema, do: @input_schema

  @doc false
  @spec output_schema() :: Zoi.schema()
  def output_schema, do: @output_schema

  @doc false
  @spec tool_module(module(), map(), non_neg_integer()) :: module()
  def tool_module(base_module, %{name: name}, index) do
    suffix =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> Macro.camelize()

    Module.concat(base_module, :"HandoffTool#{suffix}#{index}")
  end

  @doc false
  @spec tool_module_ast(module(), map()) :: Macro.t()
  def tool_module_ast(tool_module, %{name: name, description: description} = handoff) do
    quote location: :keep do
      defmodule unquote(tool_module) do
        use Jidoka.Action,
          name: unquote(name),
          description: unquote(description),
          schema: unquote(Macro.escape(Jidoka.Handoff.Tool.input_schema())),
          output_schema: unquote(Macro.escape(Jidoka.Handoff.Tool.output_schema()))

        @handoff unquote(Macro.escape(handoff))

        @impl true
        def run(params, context) do
          Jidoka.Handoff.Runtime.run_handoff_tool(@handoff, params, context)
        end
      end
    end
  end
end
