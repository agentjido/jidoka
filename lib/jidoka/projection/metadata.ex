defmodule Jidoka.Projection.Metadata do
  @moduledoc false

  alias Jidoka.Portable

  @spec agent(term()) :: term()
  def agent(metadata) when is_map(metadata) do
    metadata
    |> Map.drop([
      "dsl_module",
      :dsl_module,
      "dsl_operation_source_digest",
      :dsl_operation_source_digest
    ])
    |> Portable.project()
  end

  def agent(metadata), do: Portable.project(metadata)

  @spec turn_plan(term()) :: term()
  def turn_plan(metadata) when is_map(metadata) do
    metadata
    |> Map.drop(["dsl_operation_source_digest", :dsl_operation_source_digest])
    |> Portable.project()
  end

  def turn_plan(metadata), do: Portable.project(metadata)

  @spec operation(term()) :: term()
  def operation(metadata) when is_map(metadata) do
    has_parameters_schema? =
      is_map(Map.get(metadata, "parameters_schema") || Map.get(metadata, :parameters_schema))

    metadata
    |> Map.drop(["parameters_schema", :parameters_schema])
    |> Portable.project()
    |> Map.put("parameters_schema?", has_parameters_schema?)
  end

  def operation(metadata), do: Portable.project(metadata)

  @spec control_name(module()) :: String.t()
  def control_name(module) when is_atom(module) do
    case Jidoka.Control.control_name(module) do
      {:ok, name} -> name
      {:error, _reason} -> inspect(module)
    end
  end
end
