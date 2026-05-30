defmodule Jidoka.Turn.Cursor do
  @moduledoc "Pointer to the next safe phase boundary."

  alias Jidoka.Schema

  @phases [:start, :after_prompt, :before_effect]

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

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "turn cursor")

  def after_prompt, do: new!(phase: :after_prompt)

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
end
