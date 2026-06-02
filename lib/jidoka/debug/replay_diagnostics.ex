defmodule Jidoka.Debug.ReplayDiagnostics do
  @moduledoc """
  Diagnostic view for replayable Jidoka runtime data.

  Replay diagnostics explain whether recorded effects are complete and safe to
  reason about without executing providers or tools.
  """

  alias Jidoka.Schema

  @statuses [:complete, :waiting, :failed, :incomplete]

  @schema Zoi.struct(
            __MODULE__,
            %{
              status: Schema.atom_enum(@statuses),
              intent_count: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              result_count: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              event_count: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              missing_effect_results: Zoi.array(Zoi.map()) |> Zoi.default([]),
              failed_effect_results: Zoi.array(Zoi.map()) |> Zoi.default([]),
              unsafe_effects: Zoi.array(Zoi.map()) |> Zoi.default([]),
              pending_reviews: Zoi.array(Zoi.map()) |> Zoi.default([]),
              failed_events: Zoi.array(Zoi.map()) |> Zoi.default([]),
              warnings: Zoi.array(Zoi.string()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type status :: :complete | :waiting | :failed | :incomplete
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for replay diagnostics."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported replay diagnostic statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds replay diagnostics from normalized attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds replay diagnostics or raises when the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "debug replay diagnostics")
end
