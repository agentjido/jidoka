defmodule Jidoka.Runtime.Capabilities do
  @moduledoc "Runtime dependency bundle for interpreting effects."

  alias Jidoka.Schema

  @type llm_capability ::
          (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t() ->
             {:ok, Jidoka.Effect.LLMDecision.t() | map()} | {:error, term()})

  @type operation_capability ::
          (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t() ->
             {:ok, term()} | {:error, term()})

  @schema Zoi.struct(
            __MODULE__,
            %{
              llm: Zoi.function(arity: 3),
              operations: Zoi.function(arity: 3)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    opts
    |> Schema.normalize_attrs()
    |> Schema.put_default(:operations, &missing_operations_capability/3)
    |> then(&Schema.parse(@schema, &1))
  end

  defp missing_operations_capability(_intent, _journal, _context),
    do: {:error, :missing_operations_capability}
end
