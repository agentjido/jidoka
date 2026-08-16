defmodule Jidoka.Workflow.ParametersSchema do
  @moduledoc false

  @spec from_zoi(term()) :: map() | nil
  def from_zoi(%_{} = schema) do
    schema
    |> Zoi.to_json_schema()
    |> normalize_json_value()
  rescue
    _exception -> nil
  end

  def from_zoi(_schema), do: nil

  defp normalize_json_value(%Regex{} = regex), do: Regex.source(regex)

  defp normalize_json_value(%{} = value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value) when is_list(value), do: Enum.map(value, &normalize_json_value/1)
  defp normalize_json_value(value) when is_atom(value) and value not in [true, false, nil], do: Atom.to_string(value)
  defp normalize_json_value(value), do: value
end
