defmodule Jidoka.Workflow.ParametersSchema do
  @moduledoc false

  @spec from_zoi(term()) :: map() | nil
  def from_zoi(%Zoi.Types.Map{fields: fields}) when is_list(fields) do
    properties =
      Map.new(fields, fn {field, schema} ->
        {to_string(field), from_zoi(schema) || %{"type" => "object"}}
      end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties)
    }
  end

  def from_zoi(%Zoi.Types.Array{inner: inner}), do: %{"type" => "array", "items" => from_zoi(inner) || %{}}
  def from_zoi(%Zoi.Types.String{}), do: %{"type" => "string"}
  def from_zoi(%Zoi.Types.Number{}), do: %{"type" => "number"}
  def from_zoi(%Zoi.Types.Integer{}), do: %{"type" => "integer"}
  def from_zoi(%Zoi.Types.Float{}), do: %{"type" => "number"}
  def from_zoi(%Zoi.Types.Boolean{}), do: %{"type" => "boolean"}
  def from_zoi(%Zoi.Types.Atom{}), do: %{"type" => "string"}
  def from_zoi(%Zoi.Types.Any{}), do: %{}
  def from_zoi(%_{}), do: %{}
  def from_zoi(_schema), do: nil
end
