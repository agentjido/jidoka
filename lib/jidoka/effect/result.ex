defmodule Jidoka.Effect.Result do
  @moduledoc "Normalized result of an interpreted effect."

  alias Jidoka.Schema
  alias Jidoka.Effect

  @schema Zoi.struct(
            __MODULE__,
            %{
              intent_id: Schema.non_empty_string(),
              kind: Schema.atom_enum([:llm, :operation]),
              status: Schema.atom_enum([:ok, :error]),
              output: Zoi.any(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an interpreted effect result."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an effect result from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds an effect result and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "effect result")

  @doc "Builds a successful result for an effect intent."
  @spec ok(Effect.Intent.t(), term(), keyword()) :: t()
  def ok(intent, output, opts \\ []),
    do:
      new!(
        intent_id: intent.id,
        kind: intent.kind,
        status: :ok,
        output: output,
        metadata: Keyword.get(opts, :metadata, %{})
      )

  @doc "Builds a failed result for an effect intent."
  @spec error(Effect.Intent.t(), term(), keyword()) :: t()
  def error(intent, output, opts \\ []),
    do:
      new!(
        intent_id: intent.id,
        kind: intent.kind,
        status: :error,
        output: output,
        metadata: Keyword.get(opts, :metadata, %{})
      )
end
