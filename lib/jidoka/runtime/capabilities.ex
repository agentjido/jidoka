defmodule Jidoka.Runtime.Capabilities do
  @moduledoc """
  Advanced extension contract for injected LLM and operation capabilities.

  Application code normally passes `llm:` and `operations:` options to the
  `Jidoka` facade. Use this typed bundle when you build runtime integrations or
  low-level deterministic tests.
  """

  alias Jidoka.Schema
  alias Jidoka.Operation.Capability, as: OperationCapability

  @type llm_capability ::
          (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t() ->
             {:ok, Jidoka.Effect.LLMDecision.t() | map()} | {:error, term()})

  @type operation_capability :: OperationCapability.t()

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

  @doc "Returns the Zoi schema for runtime capabilities."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds and validates the runtime capability bundle."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    opts
    |> Schema.normalize_attrs()
    |> Schema.put_default(:operations, &OperationCapability.missing/3)
    |> then(&Schema.parse(@schema, &1))
  end
end
