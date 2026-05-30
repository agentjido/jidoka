defmodule Jidoka.Import.Registry do
  @moduledoc false

  @type registry :: keyword() | map()

  @spec fetch(atom(), atom() | String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(name, ref, opts) when is_atom(name) and is_list(opts) do
    name
    |> registry(opts)
    |> registry_lookup(ref)
    |> case do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:unknown_registry_ref, name, ref}}
    end
  end

  defp registry(:actions, opts) do
    Keyword.get(opts, :actions) ||
      Keyword.get(opts, :action_registry) ||
      nested_registry(opts, :actions) ||
      %{}
  end

  defp registry(:controls, opts) do
    Keyword.get(opts, :controls) ||
      Keyword.get(opts, :control_registry) ||
      nested_registry(opts, :controls) ||
      %{}
  end

  defp registry(:context_schemas, opts) do
    Keyword.get(opts, :context_schemas) ||
      Keyword.get(opts, :context_schema_registry) ||
      nested_registry(opts, :context_schemas) ||
      %{}
  end

  defp registry(:result_schemas, opts) do
    Keyword.get(opts, :result_schemas) ||
      Keyword.get(opts, :result_schema_registry) ||
      nested_registry(opts, :result_schemas) ||
      %{}
  end

  defp nested_registry(opts, key) do
    opts
    |> Keyword.get(:registries, %{})
    |> registry_get(key)
  end

  defp registry_lookup(registry, ref) when is_map(registry) or is_list(registry) do
    registry
    |> Enum.find(fn {key, _value} -> same_ref?(key, ref) end)
    |> case do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp registry_lookup(_registry, _ref), do: :error

  defp registry_get(registry, key) when is_map(registry) do
    Map.get(registry, key) || Map.get(registry, Atom.to_string(key))
  end

  defp registry_get(registry, key) when is_list(registry) do
    registry
    |> Enum.find(fn {registry_key, _value} -> same_ref?(registry_key, key) end)
    |> case do
      {_registry_key, value} -> value
      nil -> nil
    end
  end

  defp registry_get(_registry, _key), do: nil

  defp same_ref?(left, right) when is_binary(left) and is_binary(right), do: left == right
  defp same_ref?(left, right) when is_atom(left) and is_atom(right), do: left == right

  defp same_ref?(left, right) when is_atom(left) and is_binary(right),
    do: Atom.to_string(left) == right

  defp same_ref?(left, right) when is_binary(left) and is_atom(right),
    do: left == Atom.to_string(right)

  defp same_ref?(_left, _right), do: false
end
