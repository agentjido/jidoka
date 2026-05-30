defmodule Jidoka.Agent.Spec.Result do
  @moduledoc """
  Structured app-facing result contract for an agent.

  The result contract is intentionally provider-neutral. It stores a Zoi schema
  used by the runtime after a model returns a final decision, plus a bounded
  repair count for deterministic retry behavior.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema: Zoi.any(),
              max_repairs: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(1),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, %__MODULE__{} = result} <- Schema.parse(@schema, attrs),
         :ok <- validate_schema(result.schema) do
      {:ok, result}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "invalid agent result: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map() | term()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = result), do: new(result)

  def from_input(input) when is_map(input) or is_list(input) do
    attrs = Schema.normalize_attrs(input)

    if has_schema_key?(attrs) do
      new(attrs)
    else
      new(schema: input)
    end
  end

  def from_input(schema), do: new(schema: schema)

  @spec validate(t(), term()) :: {:ok, term()} | {:error, term()}
  def validate(%__MODULE__{schema: schema}, value) do
    case Zoi.parse(schema, normalize_value_for_schema(schema, value)) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:invalid_result_schema, exception}}
  end

  defp has_schema_key?(attrs) when is_map(attrs) do
    Map.has_key?(attrs, :schema) or Map.has_key?(attrs, "schema")
  end

  defp validate_schema(%module{}) do
    if module |> Atom.to_string() |> String.starts_with?("Elixir.Zoi.Types.") do
      :ok
    else
      {:error, {:invalid_result_schema, module}}
    end
  end

  defp validate_schema(schema), do: {:error, {:invalid_result_schema, schema}}

  defp normalize_value_for_schema(%Zoi.Types.Map{fields: fields}, %{} = value)
       when is_list(fields) do
    Enum.reduce(fields, value, fn {field, field_schema}, acc ->
      string_field = Atom.to_string(field)

      cond do
        Map.has_key?(acc, field) ->
          Map.update!(acc, field, &normalize_value_for_schema(field_schema, &1))

        Map.has_key?(acc, string_field) ->
          field_value = normalize_value_for_schema(field_schema, Map.fetch!(acc, string_field))

          acc
          |> Map.delete(string_field)
          |> Map.put(field, field_value)

        true ->
          acc
      end
    end)
  end

  defp normalize_value_for_schema(%Zoi.Types.Array{inner: inner}, value) when is_list(value) do
    Enum.map(value, &normalize_value_for_schema(inner, &1))
  end

  defp normalize_value_for_schema(_schema, value), do: value
end
