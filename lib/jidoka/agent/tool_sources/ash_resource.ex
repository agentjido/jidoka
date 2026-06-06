defmodule Jidoka.Agent.ToolSources.AshResource do
  @moduledoc false

  alias Jidoka.Agent.Dsl.AshResource
  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Agent.ToolSources.Common

  @spec action_modules(term()) :: [module()]
  def action_modules(%AshResource{} = ash_resource), do: ash_jido_actions(ash_resource)

  @spec operations!(term()) :: [Operation.t()]
  def operations!(%AshResource{} = ash_resource) do
    ash_resource
    |> ash_jido_actions()
    |> Enum.map(&Common.operation_from_action!/1)
    |> Enum.map(&tag_operation(&1, ash_resource))
  end

  @spec metadata!(term()) :: [map()]
  def metadata!(%AshResource{} = ash_resource) do
    [
      %{
        "source" => "ash_resource",
        "resource" => inspect(ash_resource.resource),
        "actions" => Common.normalize_name_list!(ash_resource.actions || [], "ash_resource actions"),
        "expanded?" => ash_jido_actions(ash_resource) != []
      }
      |> Common.reject_nil_values()
    ]
  end

  defp tag_operation(%Operation{metadata: metadata} = operation, %AshResource{} = ash_resource) do
    %Operation{
      operation
      | metadata:
          metadata
          |> Map.merge(Common.normalize_metadata!(ash_resource.metadata))
          |> Map.merge(%{
            "source" => "ash_resource",
            "kind" => "ash_resource",
            "resource" => inspect(ash_resource.resource),
            "action" => operation.name
          })
    }
  end

  defp ash_jido_actions(%AshResource{} = ash_resource) do
    with module <- ash_jido_tools_module(),
         {:module, module} <- Code.ensure_compiled(module),
         actions when is_list(actions) <- apply(module, :actions, [ash_resource.resource]) do
      maybe_filter_ash_jido_actions(actions, ash_resource.actions || [])
    else
      _reason -> []
    end
  rescue
    _exception -> []
  end

  defp ash_jido_tools_module do
    Application.get_env(:jidoka, :ash_jido_tools, AshJido.Tools)
  end

  defp maybe_filter_ash_jido_actions(actions, requested_actions)
       when requested_actions in [nil, []],
       do: actions

  defp maybe_filter_ash_jido_actions(actions, requested_actions) do
    requested = MapSet.new(Common.normalize_name_list!(requested_actions, "ash_resource actions"))

    Enum.filter(actions, fn action ->
      action_tool_name(action) in requested or action_module_name(action) in requested
    end)
  end

  defp action_tool_name(action) do
    case action.to_tool() do
      %{name: name} -> to_string(name)
      _tool -> nil
    end
  rescue
    _exception -> nil
  end

  defp action_module_name(action) do
    action
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
