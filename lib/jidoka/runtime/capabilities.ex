defmodule Jidoka.Runtime.Capabilities do
  @moduledoc """
  Advanced extension contract for injected LLM, operation, and policy capabilities.

  Application code normally passes `llm:` and `operations:` options to the
  `Jidoka` facade. Use this typed bundle when you build runtime integrations or
  low-level deterministic tests.
  """

  alias Jidoka.Schema
  alias Jidoka.Operation.Capability, as: OperationCapability
  alias Jidoka.Policy.Gate

  @type llm_capability ::
          (Jidoka.Effect.Intent.t(), Jidoka.Effect.Journal.t(), Jidoka.Context.t() ->
             {:ok, Jidoka.Effect.LLMDecision.t() | map()} | {:error, term()})

  @type operation_capability :: OperationCapability.t()
  @type policy_capability :: Gate.capability()

  @schema Zoi.struct(
            __MODULE__,
            %{
              llm: Zoi.function(arity: 3),
              operations: Zoi.function(arity: 3),
              policy: Zoi.function(arity: 2)
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
    |> defaults()
    |> then(&Schema.parse(@schema, &1))
  end

  @doc "Builds the runtime capability bundle and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    attrs = opts |> Schema.normalize_attrs() |> defaults()
    Schema.parse!(@schema, attrs, "runtime capabilities")
  end

  defp defaults(attrs) do
    attrs
    |> Schema.put_default(:operations, &OperationCapability.missing/3)
    |> Schema.put_default(:policy, &Gate.default/2)
  end
end
