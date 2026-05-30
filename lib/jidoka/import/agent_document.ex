defmodule Jidoka.Import.AgentDocument do
  @moduledoc """
  Portable JSON/YAML authoring document for a Jidoka agent.

  The document intentionally stores only data. Runtime-only values such as Zoi
  schemas and Jido action modules are referenced by name and resolved through
  explicit registries in `Jidoka.Import`.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
              agent: Zoi.map(),
              tools: Zoi.map() |> Zoi.default(%{}),
              controls: Zoi.map() |> Zoi.default(%{}),
              operations: Zoi.array(Zoi.map()) |> Zoi.default([]),
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
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "imported agent document")
end
