defmodule Jidoka.Import.Normalize do
  @moduledoc false

  alias Jidoka.Agent.Spec

  @name_regex ~r/^[a-z][a-z0-9_]*$/

  @spec stringify_keys(term()) :: term()
  def stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {stringify_key(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @spec tool_entries(map(), atom(), atom()) :: [term()]
  def tool_entries(tools, plural_key, singular_key) do
    tools
    |> first_value([plural_key, singular_key])
    |> List.wrap()
  end

  @spec first_value(map(), [atom()]) :: term()
  def first_value(map, keys) do
    Enum.find_value(keys, [], fn key ->
      case Jidoka.Schema.fetch_key(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  @spec reverse_result({:ok, list()} | {:error, term()}) :: {:ok, list()} | {:error, term()}
  def reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  def reverse_result({:error, reason}), do: {:error, reason}

  @spec name(term()) :: {:ok, String.t()} | {:error, term()}
  def name(value) when is_atom(value) and not is_nil(value) do
    value
    |> Atom.to_string()
    |> name()
  end

  def name(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@name_regex, value) do
      {:ok, value}
    else
      {:error, {:invalid_lower_snake_name, value}}
    end
  end

  def name(value), do: {:error, {:invalid_name, value}}

  @spec name_list(term(), atom()) :: {:ok, [String.t()]} | {:error, term()}
  def name_list(nil, _field), do: {:ok, []}
  def name_list(values, field) when is_list(values), do: list(values, &name/1, field)
  def name_list(value, field), do: name_list([value], field)

  @spec string_list(term(), atom()) :: {:ok, [String.t()]} | {:error, term()}
  def string_list(nil, _field), do: {:ok, []}
  def string_list(values, field) when is_list(values), do: list(values, &string/1, field)
  def string_list(value, field), do: string_list([value], field)

  @spec string(term()) :: {:ok, String.t()} | {:error, term()}
  def string(value) when is_atom(value) and not is_nil(value), do: {:ok, Atom.to_string(value)}

  def string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_empty_string, value}}
      value -> {:ok, value}
    end
  end

  def string(value), do: {:error, {:invalid_string, value}}

  @spec idempotency(term()) :: {:ok, Spec.Operation.idempotency()} | {:error, term()}
  def idempotency(value) when is_atom(value) do
    if value in Spec.Operation.valid_idempotencies() do
      {:ok, value}
    else
      {:error, {:invalid_idempotency, value}}
    end
  end

  def idempotency(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Spec.Operation.valid_idempotencies()
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> {:error, {:invalid_idempotency, value}}
      idempotency -> {:ok, idempotency}
    end
  end

  def idempotency(value), do: {:error, {:invalid_idempotency, value}}

  @spec metadata(term()) :: {:ok, map()} | {:error, term()}
  def metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  def metadata(metadata), do: {:error, {:invalid_metadata, metadata}}

  @spec metadata_value(term()) :: term()
  def metadata_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def metadata_value(value) when is_tuple(value), do: inspect(value)
  def metadata_value(value), do: value

  @spec reject_nil_values(map()) :: map()
  def reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  defp list(values, fun, field) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, values} ->
      case fun.(value) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        {:error, reason} -> {:halt, {:error, {field, reason}}}
      end
    end)
  end
end
