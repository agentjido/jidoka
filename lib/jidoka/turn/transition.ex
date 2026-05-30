defmodule Jidoka.Turn.Transition do
  @moduledoc """
  Pure transition result for turn state changes.

  Domain functions can produce state plus neutral events/diagnostics without
  depending on any concrete extension. `commit/1` appends those events to the
  state in sequence order.
  """

  alias Jidoka.Event
  alias Jidoka.Schema

  @type state :: map()

  @schema Zoi.struct(
            __MODULE__,
            %{
              state: Zoi.any(),
              events: Zoi.array(Zoi.lazy({Event, :schema, []})) |> Zoi.default([]),
              diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(state(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(state, attrs \\ []) when is_map(state) do
    attrs
    |> Schema.normalize_attrs()
    |> Map.put(:state, state)
    |> then(&Schema.parse(@schema, &1))
  end

  @spec new!(state(), keyword() | map()) :: t()
  def new!(state, attrs \\ []) when is_map(state) do
    Schema.parse!(
      @schema,
      Map.put(Schema.normalize_attrs(attrs), :state, state),
      "turn transition"
    )
  end

  @spec event(t(), atom(), keyword() | map()) :: t()
  def event(%__MODULE__{} = transition, event, attrs \\ []) do
    existing_events = Map.get(transition.state, :events, []) ++ transition.events
    event = Event.build(event, existing_events, attrs)
    %__MODULE__{transition | events: transition.events ++ [event]}
  end

  @spec diagnostic(t(), term()) :: t()
  def diagnostic(%__MODULE__{} = transition, diagnostic) do
    %__MODULE__{transition | diagnostics: transition.diagnostics ++ [diagnostic]}
  end

  @spec commit(t()) :: state()
  def commit(%__MODULE__{state: state, events: events, diagnostics: diagnostics}) do
    state
    |> Map.put(:events, Map.get(state, :events, []) ++ events)
    |> Map.put(:diagnostics, Map.get(state, :diagnostics, []) ++ diagnostics)
  end
end
