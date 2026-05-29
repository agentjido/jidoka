defmodule Jidoka.Effect.Intent do
  @moduledoc "Data description of an external effect the runtime may interpret."

  alias Jidoka.Agent.Spec.Operation
  alias Jidoka.Schema

  @type kind :: :llm | :operation

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Schema.non_empty_string(),
              kind: Zoi.enum([:llm, :operation]),
              payload: Zoi.map(),
              idempotency_key: Schema.non_empty_string(),
              idempotency: Zoi.enum(Operation.valid_idempotencies()) |> Zoi.default(:idempotent),
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

  @spec new(kind(), map(), keyword()) :: t()
  def new(kind, payload, opts \\ []) do
    key = Keyword.get(opts, :idempotency_key) || idempotency_key(kind, payload)

    new!(%{
      id: Keyword.get(opts, :id) || effect_id(kind, key),
      kind: kind,
      payload: payload,
      idempotency_key: key,
      idempotency: Keyword.get(opts, :idempotency, :idempotent),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "effect intent")

  defp effect_id(kind, key), do: "#{kind}:" <> key

  defp idempotency_key(kind, payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary({kind, payload}))
    |> Base.url_encode64(padding: false)
  end
end
