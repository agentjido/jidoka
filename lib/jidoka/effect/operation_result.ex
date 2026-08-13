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
              tool_call: Zoi.lazy({Effect.ToolCall, :schema, []}) |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an operation result."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds an operation result from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds an operation result and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "operation result")

  @doc "Normalizes an existing operation result, keyword list, or map."
  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = result), do: new(result)
  def from_input(input), do: new(input)

  @doc "Builds an operation result from an operation intent and its output."
  @spec from_effect(Effect.Intent.t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_effect(%Effect.Intent{kind: :operation, payload: payload} = intent, output, opts \\ []) do
    with {:ok, request} <- Effect.OperationRequest.from_input(payload) do
      new(
        operation: request.name,
        arguments: request.arguments,
        output: output,
        content: encode_content(output),
        request_id: request.request_id,
        loop_index: request.loop_index,
        effect_id: intent.id,
        tool_call: request.tool_call,
        metadata: Keyword.get(opts, :metadata, %{})
      )
    end
  end

  @doc "Converts an operation result to a tool message for the model."
  @spec to_message(t()) :: Agent.Message.t()
  def to_message(%__MODULE__{} = result) do
    Agent.Message.tool(result.operation, result.output,
      id: message_id(result),
      request_id: result.request_id,
      content: result.content || inspect(result.output),
      tool_call: result.tool_call,
      metadata: result.metadata
    )
  end

  defp encode_content(output) do
    case Jason.encode(output) do
      {:ok, content} -> content
      {:error, _reason} -> inspect(output)
    end
  end

  defp message_id(%__MODULE__{tool_call: %Effect.ToolCall{} = call, request_id: request_id}) do
    Jidoka.Id.stable("msg", [
      request_id,
      :tool_result,
      call.interaction_id,
      call.group_id,
      call.call_index
    ])
  end

  defp message_id(%__MODULE__{request_id: request_id, effect_id: effect_id}) do
    Jidoka.Id.stable("msg", [request_id, :tool_result, effect_id])
  end
end
