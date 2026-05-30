defmodule Jidoka.Extension.Patch do
  @moduledoc """
  Validated contribution from an extension into the core agent definition.

  The first spike keeps this intentionally small. Future extensions can grow
  this contract, but patches should remain data-only and mergeable.
  """

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              operations: Zoi.array(Zoi.lazy({Operation, :schema, []})) |> Zoi.default([]),
              runtime_defaults: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{}),
              diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([])
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
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "extension patch")
end
