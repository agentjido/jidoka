defmodule Jidoka.Agent.Spec do
  @moduledoc """
  Canonical immutable definition of a Jidoka agent.
  """

  alias Jidoka.Config
  alias Jidoka.Agent.Spec.{Generation, Operation}
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              instructions: Schema.non_empty_string(),
              model: Zoi.lazy({LLMDB.Model, :schema, []}),
              generation: Zoi.lazy({Generation, :schema, []}),
              context_schema: Zoi.any() |> Zoi.nullish(),
              operations: Zoi.array(Zoi.lazy({Operation, :schema, []})) |> Zoi.default([]),
              runtime_defaults: Zoi.map() |> Zoi.default(%{}),
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
    with {:ok, attrs} <- normalize_model_input(attrs),
         {:ok, attrs} <- normalize_generation_input(attrs) do
      Schema.parse(@schema, attrs)
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, spec} -> spec
      {:error, reason} -> raise ArgumentError, "invalid agent spec: #{inspect(reason)}"
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = spec), do: new(spec)
  def from_input(input), do: new(input)

  @spec validate_context(t(), map()) :: :ok | {:error, term()}
  def validate_context(%__MODULE__{context_schema: nil}, context) when is_map(context), do: :ok

  def validate_context(%__MODULE__{context_schema: schema}, context) when is_map(context) do
    case Zoi.parse(schema, context) do
      {:ok, _validated_context} -> :ok
      {:error, reason} -> {:error, {:invalid_context, reason}}
    end
  rescue
    exception -> {:error, {:invalid_context_schema, exception}}
  end

  defp normalize_model_input(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    case raw_model(attrs) do
      nil ->
        {:ok, put_model(attrs, Config.default_model())}

      model ->
        with {:ok, model} <- Config.normalize_model_spec(model) do
          {:ok, put_model(attrs, model)}
        end
    end
  end

  defp normalize_generation_input(attrs) do
    case raw_generation(attrs) do
      nil ->
        {:ok, put_generation(attrs, Config.default_generation())}

      generation ->
        with {:ok, generation} <- Config.normalize_generation(generation) do
          {:ok, put_generation(attrs, generation)}
        end
    end
  end

  defp raw_model(attrs) when is_map(attrs) do
    Map.get(attrs, :model, Map.get(attrs, "model"))
  end

  defp raw_generation(attrs) when is_map(attrs) do
    Map.get(attrs, :generation, Map.get(attrs, "generation"))
  end

  defp put_model(attrs, model) when is_map(attrs) do
    attrs
    |> Map.delete("model")
    |> Map.put(:model, model)
  end

  defp put_generation(attrs, generation) when is_map(attrs) do
    attrs
    |> Map.delete("generation")
    |> Map.put(:generation, generation)
  end
end
