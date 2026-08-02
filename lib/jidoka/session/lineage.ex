defmodule Jidoka.Session.Lineage do
  @moduledoc """
  Durable parentage for a session created from a safe snapshot fork.

  Lineage identifies the direct parent, the source snapshot, and the root of
  the fork tree. It does not permit state mutation or effect re-execution.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              root_session_id: Schema.non_empty_string(),
              parent_session_id: Schema.non_empty_string(),
              source_snapshot_id: Schema.non_empty_string(),
              forked_at_ms: Zoi.integer() |> Zoi.gte(0),
              depth: Zoi.integer() |> Zoi.gte(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for session lineage."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds session lineage from keyword or map attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds session lineage and raises if the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "session lineage")

  @doc "Builds the next lineage record for a session fork."
  @spec next(t() | nil, String.t(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, term()}
  def next(lineage, parent_session_id, snapshot_id, forked_at_ms)
      when (is_struct(lineage, __MODULE__) or is_nil(lineage)) and
             is_binary(parent_session_id) and is_binary(snapshot_id) and
             is_integer(forked_at_ms) do
    {root_session_id, depth} =
      case lineage do
        %__MODULE__{root_session_id: root_session_id, depth: depth} ->
          {root_session_id, depth + 1}

        nil ->
          {parent_session_id, 1}
      end

    new(
      root_session_id: root_session_id,
      parent_session_id: parent_session_id,
      source_snapshot_id: snapshot_id,
      forked_at_ms: forked_at_ms,
      depth: depth
    )
  end
end
