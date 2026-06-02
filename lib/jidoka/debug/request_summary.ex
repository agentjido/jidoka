defmodule Jidoka.Debug.RequestSummary do
  @moduledoc """
  Request-level debug summary assembled from Jidoka runtime data.

  This is a data-only view. It does not call providers, tools, or runtime
  capabilities.
  """

  alias Jidoka.Schema

  @schema Zoi.struct(
            __MODULE__,
            %{
              request_id: Schema.non_empty_string() |> Zoi.nullish(),
              agent_id: Schema.non_empty_string() |> Zoi.nullish(),
              session_id: Schema.non_empty_string() |> Zoi.nullish(),
              status: Zoi.atom() |> Zoi.nullish(),
              model: Zoi.string() |> Zoi.nullish(),
              input: Zoi.string() |> Zoi.nullish(),
              content: Zoi.string() |> Zoi.nullish(),
              value: Zoi.any() |> Zoi.nullish(),
              prompt: Zoi.map() |> Zoi.default(%{}),
              context_keys: Zoi.array(Zoi.string()) |> Zoi.default([]),
              operation_names: Zoi.array(Zoi.string()) |> Zoi.default([]),
              operation_results: Zoi.array(Zoi.map()) |> Zoi.default([]),
              memory: Zoi.map() |> Zoi.nullish(),
              usage: Zoi.map() |> Zoi.default(%{}),
              timeline: Zoi.array(Zoi.map()) |> Zoi.default([]),
              journal: Zoi.map() |> Zoi.default(%{intents: [], results: []}),
              pending_reviews: Zoi.array(Zoi.map()) |> Zoi.default([]),
              diagnostics: Zoi.array(Zoi.any()) |> Zoi.default([]),
              replay_diagnostics: Zoi.lazy({Jidoka.Debug.ReplayDiagnostics, :schema, []}) |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for request debug summaries."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a request debug summary from normalized attributes."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a request debug summary or raises when the attributes are invalid."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "debug request summary")
end
