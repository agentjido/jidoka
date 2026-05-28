defmodule Jidoka.Trace.Event do
  @moduledoc """
  Normalized Jidoka trace event.

  Events are a Jidoka-friendly projection of Jido/Jido.AI telemetry plus
  Jidoka-specific lifecycle events.

  `schema_version/0` identifies the normalized event struct contract used by
  AgentView, Kino, Livebook helpers, and external UI projections. The stable
  contract is the top-level struct fields; `metadata` and `measurements` remain
  source-specific diagnostic maps unless a field is promoted into the struct.
  """

  @schema_version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          seq: pos_integer(),
          at_ms: integer(),
          source: atom(),
          category: atom(),
          event: atom(),
          phase: atom() | nil,
          name: String.t() | nil,
          status: atom() | nil,
          duration_ms: non_neg_integer() | nil,
          request_id: String.t() | nil,
          run_id: String.t() | nil,
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          parent_span_id: String.t() | nil,
          measurements: map(),
          metadata: map()
        }

  @doc """
  Returns the current normalized trace event schema version.

  Additive top-level fields keep the same major version. Renaming or removing a
  top-level field requires a new version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @enforce_keys [
    :seq,
    :at_ms,
    :source,
    :category,
    :event,
    :measurements,
    :metadata
  ]
  defstruct [
    :seq,
    :at_ms,
    :source,
    :category,
    :event,
    :phase,
    :name,
    :status,
    :duration_ms,
    :request_id,
    :run_id,
    :trace_id,
    :span_id,
    :parent_span_id,
    schema_version: @schema_version,
    measurements: %{},
    metadata: %{}
  ]
end
