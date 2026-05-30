defmodule Jidoka.Turn.Result do
  @moduledoc "Final app-facing result of one Jidoka turn."

  alias Jidoka.Schema
  alias Jidoka.Agent
  alias Jidoka.Effect
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              content: Zoi.string(),
              agent_state: Zoi.lazy({Agent.State, :schema, []}),
              journal: Zoi.lazy({Effect.Journal, :schema, []}),
              events: Zoi.array(Zoi.lazy({Jidoka.Event, :schema, []})) |> Zoi.default([]),
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
  def new!(attrs), do: Schema.parse!(@schema, attrs, "turn result")

  @spec from_turn_state!(Turn.State.t()) :: t()
  def from_turn_state!(%Turn.State{status: :finished, result: content} = state) do
    new!(
      content: content,
      agent_state: state.agent_state,
      journal: state.journal,
      events: state.events
    )
  end
end
