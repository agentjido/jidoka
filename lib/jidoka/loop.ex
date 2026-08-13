defmodule Jidoka.Loop.Counts do
  @moduledoc "Portable logical-work counts for user turns, model steps, and tool calls."

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              user_turns: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              model_steps: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_call_groups: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              tool_calls: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the loop-count schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds loop counts."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs \\ []), do: Schema.parse(@schema, attrs)

  @doc "Builds loop counts or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs \\ []), do: Schema.parse!(@schema, attrs, "loop counts")
end

defmodule Jidoka.Loop do
  @moduledoc """
  Canonical vocabulary and logical counters for the Jidoka agent loop.

  A **user turn** is one user request and all work needed to produce its
  terminal result. One call to `Jidoka.turn/3` executes one user turn.

  A **model step** is one logical model decision inside a user turn. A model
  step returns a final answer or one tool-call group. The existing
  `:max_model_turns` option limits model steps; its name remains for
  compatibility.

  A **tool call** is one requested operation. A **tool-call group** is the one
  or more tool calls returned by one model step. Calls in a group must be
  independent, even when the runtime executes them serially.

  A **dependent tool sequence** has two or more tool-call groups in one user
  turn. A later model step can use results from an earlier group to choose its
  next calls.

  Counts are logical protocol counts. Provider transport retries and journal
  replay do not add model steps or tool calls.
  """

  alias Jidoka.Effect
  alias Jidoka.Loop.Counts
  alias Jidoka.Turn

  @typedoc "Number of completed user requests."
  @type user_turn_count :: non_neg_integer()

  @typedoc "Zero-based position of one model step inside a user turn."
  @type model_step_index :: non_neg_integer()

  @typedoc "Number of logical model decisions."
  @type model_step_count :: non_neg_integer()

  @typedoc "Zero-based position of one tool call inside its group."
  @type tool_call_index :: non_neg_integer()

  @typedoc "Number of tool-call groups."
  @type tool_call_group_count :: non_neg_integer()

  @typedoc "Number of logical operation calls."
  @type tool_call_count :: non_neg_integer()

  @doc "Counts logical loop work in one result or an ordered result list."
  @spec counts(Turn.Result.t() | [Turn.Result.t()]) :: Counts.t()
  def counts(%Turn.Result{journal: %Effect.Journal{} = journal}) do
    intents = Map.values(journal.intents)
    operation_intents = Enum.filter(intents, &match?(%Effect.Intent{kind: :operation}, &1))

    Counts.new!(
      user_turns: 1,
      model_steps: Enum.count(intents, &match?(%Effect.Intent{kind: :llm}, &1)),
      tool_call_groups: count_tool_call_groups(operation_intents),
      tool_calls: length(operation_intents)
    )
  end

  def counts(results) when is_list(results) do
    results
    |> Enum.map(&counts/1)
    |> Enum.reduce(Counts.new!(), &add_counts/2)
  end

  defp count_tool_call_groups(operation_intents) do
    operation_intents
    |> Enum.map(&tool_call_group_key/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp tool_call_group_key(%Effect.Intent{payload: payload}) do
    request = Effect.OperationRequest.new!(payload)
    {request.request_id, request.loop_index}
  end

  defp add_counts(%Counts{} = next, %Counts{} = total) do
    Counts.new!(
      user_turns: total.user_turns + next.user_turns,
      model_steps: total.model_steps + next.model_steps,
      tool_call_groups: total.tool_call_groups + next.tool_call_groups,
      tool_calls: total.tool_calls + next.tool_calls
    )
  end
end
