defmodule Jidoka.Turn.Cursor do
  @moduledoc "Pointer to the next safe phase boundary."

  alias Jidoka.Schema

  @phases [:start, :after_prompt, :before_effect, :review, :wait]

  @schema Zoi.struct(
            __MODULE__,
            %{
              phase: Schema.atom_enum(@phases) |> Zoi.default(:start),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a turn cursor."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a turn cursor from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @doc "Builds a turn cursor and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "turn cursor")

  @doc "Builds a cursor for the boundary after prompt assembly."
  @spec after_prompt() :: t()
  def after_prompt, do: new!(phase: :after_prompt)

  @doc "Builds a cursor for the boundary before one effect is interpreted."
  @spec before_effect(Jidoka.Effect.Intent.t() | nil) :: t()
  def before_effect(nil), do: new!(phase: :before_effect)

  def before_effect(effect) do
    new!(
      phase: :before_effect,
      metadata: %{
        "effect_id" => Map.get(effect, :id),
        "effect_kind" => Map.get(effect, :kind)
      }
    )
  end

  @doc "Builds a cursor for a pending human-review boundary."
  @spec review(Jidoka.Review.Interrupt.t()) :: t()
  def review(interrupt) do
    new!(
      phase: :review,
      metadata: %{
        "interrupt_id" => Map.get(interrupt, :id),
        "boundary" => Map.get(interrupt, :boundary),
        "operation" => Map.get(interrupt, :operation)
      }
    )
  end
end
