defmodule Jidoka.Review.Response do
  @moduledoc """
  Application response to a pending review request.

  A response is intentionally small: it targets a single interrupt and either
  approves or denies the pending operation.
  """

  alias Jidoka.Review.Interrupt
  alias Jidoka.Review.Request
  alias Jidoka.Schema

  @decisions [:approved, :denied]

  @schema Zoi.struct(
            __MODULE__,
            %{
              interrupt_id: Schema.non_empty_string(),
              decision: Schema.atom_enum(@decisions),
              reason: Zoi.any() |> Zoi.nullish(),
              responded_at_ms: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type decision :: :approved | :denied
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a review response."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported review decisions."
  @spec decisions() :: [decision()]
  def decisions, do: @decisions

  @doc "Builds a review response from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a review response and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "review response")

  @doc "Normalizes an existing response, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = response), do: new(response)
  def from_input(input), do: new(input)

  @doc "Builds an approval response for an interrupt, request, or review identifier."
  @spec approve(Interrupt.t() | Request.t() | String.t(), keyword()) :: t()
  def approve(interrupt_or_id, opts \\ []) do
    new!(
      interrupt_id: interrupt_id(interrupt_or_id),
      decision: :approved,
      reason: Keyword.get(opts, :reason),
      responded_at_ms: Keyword.get(opts, :responded_at_ms),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Builds a denial response for an interrupt, request, or review identifier."
  @spec deny(Interrupt.t() | Request.t() | String.t(), keyword()) :: t()
  def deny(interrupt_or_id, opts \\ []) do
    new!(
      interrupt_id: interrupt_id(interrupt_or_id),
      decision: :denied,
      reason: Keyword.get(opts, :reason),
      responded_at_ms: Keyword.get(opts, :responded_at_ms),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp interrupt_id(%Interrupt{id: id}), do: id
  defp interrupt_id(%Request{interrupt_id: id}), do: id
  defp interrupt_id(id) when is_binary(id), do: id
end
