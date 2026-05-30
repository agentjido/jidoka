defmodule Jidoka.Effect.OperationResult do
  @moduledoc """
  Durable operation observation stored on agent state.

  This is separate from `Jidoka.Effect.Result`: the effect result records
  interpreter status, while operation result records the semantic tool
  observation that should survive across later turns.
  """

  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              operation: Schema.non_empty_string(),
              arguments: Zoi.map() |> Zoi.default(%{}),
              output: Zoi.any(),
              content: Zoi.string() |> Zoi.nullish(),
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              loop_index: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              effect_id: Schema.non_empty_string() |> Zoi.nullish(),
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
  def new!(attrs), do: Schema.parse!(@schema, attrs, "operation result")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = result), do: new(result)
  def from_input(input), do: new(input)

  @spec from_effect(Effect.Intent.t(), term()) :: {:ok, t()} | {:error, term()}
  def from_effect(%Effect.Intent{kind: :operation, payload: payload} = intent, output) do
    with {:ok, request} <- Effect.OperationRequest.from_input(payload) do
      new(
        operation: request.name,
        arguments: request.arguments,
        output: output,
        content: inspect(output),
        request_id: request.request_id,
        loop_index: request.loop_index,
        effect_id: intent.id
      )
    end
  end

  @spec to_message(t()) :: Agent.Message.t()
  def to_message(%__MODULE__{} = result) do
    Agent.Message.tool(result.operation, result.output,
      content: result.content || inspect(result.output)
    )
  end
end
