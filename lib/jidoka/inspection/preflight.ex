defmodule Jidoka.Inspection.Preflight do
  @moduledoc """
  Data returned by `Jidoka.preflight/3`.

  Preflight is intentionally effect-free. It shows the normalized agent, plan,
  request, and prompt that would be used by a turn without calling the LLM or
  any operations.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              agent: Zoi.map(),
              plan: Zoi.map(),
              request: Zoi.map(),
              prompt: Zoi.map(),
              events: Zoi.array(Zoi.map()) |> Zoi.default([]),
              timeline: Zoi.array(Zoi.map()) |> Zoi.default([]),
              diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for preflight inspection data."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds preflight inspection data from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds preflight inspection data and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "inspection preflight")
end
