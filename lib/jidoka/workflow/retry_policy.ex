defmodule Jidoka.Workflow.RetryPolicy do
  @moduledoc "Data contract for local workflow step retry policy."

  alias Jidoka.Schema

  @backoff_types [:fixed, :exponential]

  @backoff_schema Zoi.object(%{
                    type: Schema.atom_enum(@backoff_types) |> Zoi.default(:fixed),
                    min: Zoi.integer(coerce: true) |> Zoi.gte(0) |> Zoi.default(0),
                    max: Zoi.integer(coerce: true) |> Zoi.gte(0) |> Zoi.default(0)
                  })

  @schema Zoi.struct(
            __MODULE__,
            %{
              max_attempts: Zoi.integer(coerce: true) |> Zoi.gte(1) |> Zoi.default(1),
              backoff: @backoff_schema |> Zoi.default(%{type: :fixed, min: 0, max: 0})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for workflow retry policies."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported retry backoff types."
  @spec backoff_types() :: [atom()]
  def backoff_types, do: @backoff_types

  @doc "Parses retry policy attributes."
  @spec new(keyword() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def new(nil), do: {:ok, nil}
  def new(attrs), do: Schema.parse(@schema, normalize_attrs(attrs))

  @doc "Parses retry policy attributes or raises."
  @spec new!(keyword() | map() | nil) :: t() | nil
  def new!(nil), do: nil
  def new!(attrs), do: Schema.parse!(@schema, normalize_attrs(attrs), "workflow retry policy")

  defp normalize_attrs(attrs) do
    attrs
    |> Schema.normalize_attrs()
    |> normalize_backoff()
  end

  defp normalize_backoff(%{} = attrs) do
    case Schema.fetch_key(attrs, :backoff) do
      {:ok, backoff} when is_list(backoff) -> Map.put(attrs, :backoff, Map.new(backoff))
      _other -> attrs
    end
  end

  defp normalize_backoff(attrs), do: attrs
end
