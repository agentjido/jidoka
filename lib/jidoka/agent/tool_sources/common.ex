defmodule Jidoka.Agent.ToolSources.Common do
  @moduledoc false

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Runtime.JidoActions

  @spec operation_from_action!(module()) :: Operation.t()
  def operation_from_action!(action) do
    with {:module, _module} <- Code.ensure_compiled(action),
         true <- function_exported?(action, :to_tool, 0) do
      JidoActions.operation_from_action!(action)
    else
      {:error, reason} ->
        raise ArgumentError,
              "could not compile action #{inspect(action)}: #{inspect(reason)}"

      false ->
        raise ArgumentError, "#{inspect(action)} must expose `to_tool/0`"
    end
  end

  @spec normalize_name!(term(), String.t()) :: String.t()
  def normalize_name!(value, label) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> normalize_name!(label)
  end

  def normalize_name!(value, label) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value) do
      value
    else
      raise ArgumentError, "#{label} must be lower snake case, got: #{inspect(value)}"
    end
  end

  def normalize_name!(value, label) do
    raise ArgumentError, "#{label} must be an atom or string, got: #{inspect(value)}"
  end

  @spec normalize_name_list!(term(), String.t()) :: [String.t()]
  def normalize_name_list!(nil, _label), do: []
  def normalize_name_list!(values, label) when is_list(values), do: Enum.map(values, &normalize_name!(&1, label))
  def normalize_name_list!(value, label), do: [normalize_name!(value, label)]

  @spec normalize_string!(term(), String.t()) :: String.t()
  def normalize_string!(value, _label) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  def normalize_string!(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> raise ArgumentError, "#{label} cannot include empty strings"
      value -> value
    end
  end

  def normalize_string!(value, label) do
    raise ArgumentError, "#{label} entries must be atoms or strings, got: #{inspect(value)}"
  end

  @spec normalize_string_list!(term(), String.t()) :: [String.t()]
  def normalize_string_list!(nil, _label), do: []
  def normalize_string_list!(values, label) when is_list(values), do: Enum.map(values, &normalize_string!(&1, label))
  def normalize_string_list!(value, label), do: [normalize_string!(value, label)]

  @spec normalize_metadata!(term()) :: map()
  def normalize_metadata!(nil), do: %{}
  def normalize_metadata!(metadata) when is_map(metadata), do: metadata

  def normalize_metadata!(metadata) do
    raise ArgumentError, "tool metadata must be a map, got: #{inspect(metadata)}"
  end

  @spec metadata_value(term()) :: term()
  def metadata_value(nil), do: nil
  def metadata_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def metadata_value(value) when is_binary(value), do: value
  def metadata_value(value), do: inspect(value)

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
