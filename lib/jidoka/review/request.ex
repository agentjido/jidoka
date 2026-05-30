defmodule Jidoka.Review.Request do
  @moduledoc """
  Application-facing request for human review of an interrupted operation.
  """

  alias Jidoka.Review.Interrupt
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              interrupt_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              request_id: Schema.non_empty_string(),
              boundary: Schema.atom_enum([:operation]),
              operation: Schema.non_empty_string(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              reason: Zoi.any(),
              created_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              expires_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
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
  def new!(attrs), do: Schema.parse!(@schema, attrs, "review request")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = request), do: new(request)
  def from_input(input), do: new(input)

  @spec from_interrupt(Interrupt.t()) :: {:ok, t()} | {:error, term()}
  def from_interrupt(%Interrupt{} = interrupt) do
    new(
      id: "review:" <> interrupt.id,
      interrupt_id: interrupt.id,
      agent_id: interrupt.agent_id,
      request_id: interrupt.request_id,
      boundary: interrupt.boundary,
      operation: interrupt.operation,
      arguments: interrupt.arguments,
      reason: interrupt.reason,
      created_at_ms: interrupt.created_at_ms,
      expires_at_ms: interrupt.expires_at_ms,
      metadata: interrupt.metadata
    )
  end

  @spec from_interrupt!(Interrupt.t()) :: t()
  def from_interrupt!(%Interrupt{} = interrupt) do
    case from_interrupt(interrupt) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid review request: #{inspect(reason)}"
    end
  end
end
