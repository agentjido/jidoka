defmodule Jidoka.Operation.Source.Catalog.Normalize do
  @moduledoc false

  alias Jido.Action.Catalog, as: ActionCatalog
  alias Jido.Action.Catalog.Entry
  alias Jidoka.Agent.Spec.Operation

  @default_prefix "catalog_"
  @result_modes [:structured]

  def catalog_module(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        if function_exported?(module, :catalog, 0) do
          {:ok, module}
        else
          {:error, {:invalid_catalog_module, module, :missing_catalog_callback}}
        end

      {:error, reason} ->
        {:error, {:invalid_catalog_module, module, reason}}
    end
  end

  def catalog_module(module), do: {:error, {:invalid_catalog_module, module}}

  def catalog_value(module) do
    case module.catalog() do
      %ActionCatalog{} = catalog -> {:ok, catalog}
      other -> {:error, {:invalid_catalog_return, module, other}}
    end
  rescue
    exception -> {:error, {:invalid_catalog_return, module, exception}}
  end

  def templates(module) do
    if function_exported?(module, :templates, 0) do
      case module.templates() do
        templates when is_map(templates) -> {:ok, stringify_keys(templates)}
        templates -> {:error, {:invalid_catalog_templates, module, templates}}
      end
    else
      {:ok, %{}}
    end
  rescue
    exception -> {:error, {:invalid_catalog_templates, module, exception}}
  end

  def prefix(nil), do: {:ok, @default_prefix}
  def prefix(prefix) when is_atom(prefix) and not is_nil(prefix), do: prefix |> Atom.to_string() |> prefix()

  def prefix(prefix) when is_binary(prefix) do
    prefix = String.trim(prefix)

    cond do
      prefix == "" ->
        {:ok, @default_prefix}

      Regex.match?(~r/^[a-z][a-z0-9_]*_$/, prefix) ->
        {:ok, prefix}

      Regex.match?(~r/^[a-z][a-z0-9_]*$/, prefix) ->
        {:ok, prefix <> "_"}

      true ->
        {:error, {:invalid_catalog_prefix, prefix}}
    end
  end

  def prefix(prefix), do: {:error, {:invalid_catalog_prefix, prefix}}

  def positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  def positive_integer(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_catalog_positive_integer, field, value}}
    end
  end

  def positive_integer(value, field), do: {:error, {:invalid_catalog_positive_integer, field, value}}

  def boolean(value, _field) when is_boolean(value), do: {:ok, value}
  def boolean(value, field), do: {:error, {:invalid_catalog_boolean, field, value}}

  def result(result) when result in @result_modes, do: {:ok, result}
  def result(result), do: {:error, {:invalid_catalog_result, result}}

  def idempotency(idempotency) when is_atom(idempotency) do
    if idempotency in Operation.valid_idempotencies() do
      {:ok, idempotency}
    else
      {:error, {:invalid_catalog_idempotency, idempotency}}
    end
  end

  def idempotency(idempotency), do: {:error, {:invalid_catalog_idempotency, idempotency}}

  def metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  def metadata(metadata), do: {:error, {:invalid_catalog_metadata, metadata}}

  def context(context) when is_map(context), do: context
  def context(context) when is_list(context), do: Map.new(context)
  def context(_context), do: %{}

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def positive_integer_or_default(value, _default) when is_integer(value) and value > 0, do: value

  def positive_integer_or_default(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  def positive_integer_or_default(_value, default), do: default

  def clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)

  def lua_metadata(%Entry{metadata: %{"lua" => metadata}}, key), do: Map.get(metadata, key)
  def lua_metadata(%Entry{metadata: %{lua: metadata}}, key), do: Map.get(metadata, key)
  def lua_metadata(_entry, _key), do: nil

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(reason), do: inspect(reason)

  def reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
