defmodule Jidoka.Runtime.AgentSnapshot do
  @moduledoc "Serializable semantic snapshot for hibernate/resume."

  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.integer() |> Zoi.positive() |> Zoi.default(@schema_version),
              snapshot_id: Schema.non_empty_string(),
              agent_id: Schema.non_empty_string(),
              cursor: Zoi.lazy({Turn.Cursor, :schema, []}),
              turn_state: Zoi.lazy({Turn.State, :schema, []}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "agent snapshot")

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def from_input(%__MODULE__{} = snapshot), do: new(snapshot)
  def from_input(input), do: new(input)

  @spec from_turn_state!(Turn.State.t(), Turn.Cursor.t()) :: t()
  def from_turn_state!(%Turn.State{} = state, %Turn.Cursor{} = cursor) do
    new!(
      schema_version: @schema_version,
      snapshot_id: "snap_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
      agent_id: state.spec.id,
      cursor: %Turn.Cursor{cursor | loop_index: state.loop_index},
      turn_state: state
    )
  end
end
