defmodule Jidoka.Effect.OperationRequest do
  @moduledoc """
  Typed request payload for an operation effect.

  Operation effects are still interpreted by runtime capabilities, but this
  struct defines the durable data shape those capabilities receive.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Schema.non_empty_string(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
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
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "operation request")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = request), do: new(request)
  def from_input(input), do: new(input)

  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = request) do
    request
    |> Map.from_struct()
    |> Map.reject(fn
      {_key, nil} -> true
      {:metadata, metadata} when metadata == %{} -> true
      {_key, _value} -> false
    end)
  end
end
