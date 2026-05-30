defmodule Jidoka.Agent.Spec.Operation do
  @moduledoc """
  Model-callable operation definition.
  """

  alias Jidoka.Schema

  @type idempotency :: :pure | :idempotent | :dedupe | :reconcile | :unsafe_once

  @valid_idempotency [:pure, :idempotent, :dedupe, :reconcile, :unsafe_once]
  @idempotency_schema Schema.atom_enum(@valid_idempotency)

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Schema.non_empty_string(),
              description: Zoi.string() |> Zoi.nullish(),
              idempotency: @idempotency_schema |> Zoi.default(:idempotent),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec valid_idempotencies() :: [idempotency()]
  def valid_idempotencies, do: @valid_idempotency

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "operation")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = operation), do: new(operation)
  def from_input(input), do: new(input)
end
