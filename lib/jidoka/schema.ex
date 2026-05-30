defmodule Jidoka.Schema do
  @moduledoc """
  Small Zoi helpers for Jidoka's data-first structs.

  This module is intentionally narrow. It keeps repeated constructor mechanics
  in one place while each domain module owns its actual Zoi schema.
  """

  @type parse_result(t) :: {:ok, t} | {:error, term()}

  @spec parse(Zoi.schema(), keyword() | map()) :: parse_result(struct())
  def parse(schema, attrs) do
    Zoi.parse(schema, normalize_attrs(attrs))
  end

  @spec parse!(Zoi.schema(), keyword() | map(), String.t()) :: struct()
  def parse!(schema, attrs, label) do
    case parse(schema, attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid #{label}: #{inspect(reason)}"
    end
  end

  @spec normalize_attrs(term()) :: term()
  def normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  def normalize_attrs(%_{} = attrs), do: Map.from_struct(attrs)
  def normalize_attrs(attrs), do: attrs

  @spec non_empty_string() :: Zoi.schema()
  def non_empty_string, do: Zoi.string(coerce: true) |> Zoi.min(1)

  @spec atom_enum([atom()]) :: Zoi.schema()
  def atom_enum(values) when is_list(values) do
    Zoi.union([
      Zoi.enum(values),
      Zoi.string() |> Zoi.transform({__MODULE__, :parse_atom_enum, [values]})
    ])
  end

  @doc false
  def parse_atom_enum(value, values, _opts) when is_binary(value) and is_list(values) do
    case Enum.find(values, &(Atom.to_string(&1) == value)) do
      nil -> {:error, "invalid enum value: #{value}"}
      value -> {:ok, value}
    end
  end

  @spec put_default(map(), atom(), term()) :: map()
  def put_default(attrs, key, value) when is_map(attrs) do
    string_key = Atom.to_string(key)

    if Map.has_key?(attrs, key) or Map.has_key?(attrs, string_key) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  def put_default(attrs, _key, _value), do: attrs

  @spec fetch_key(map(), atom()) :: {:ok, term()} | :error
  def fetch_key(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  @spec get_key(map(), atom(), term()) :: term()
  def get_key(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    case fetch_key(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end
end
