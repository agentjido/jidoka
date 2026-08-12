defmodule Jidoka.Session.Sequence.Step do
  @moduledoc "One completed turn in an ordered session sequence."

  alias Jidoka.Effect
  alias Jidoka.Schema
  alias Jidoka.Turn

  @schema Zoi.struct(
            __MODULE__,
            %{
              index: Zoi.integer() |> Zoi.positive(),
              request: Zoi.lazy({Turn.Request, :schema, []}),
              result: Zoi.lazy({Turn.Result, :schema, []}),
              operation_results:
                Zoi.array(Zoi.lazy({Effect.OperationResult, :schema, []}))
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a completed sequence step."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds one completed sequence step."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds one completed sequence step or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "session sequence step")
end

defmodule Jidoka.Session.Sequence.Terminal do
  @moduledoc "Terminal data for an incomplete ordered session sequence."

  alias Jidoka.Cancellation
  alias Jidoka.Schema
  alias Jidoka.Snapshot

  @kinds [:error, :hibernated, :cancelled]

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Schema.atom_enum(@kinds),
              index: Zoi.integer() |> Zoi.positive(),
              request_id: Zoi.string() |> Zoi.nullish(),
              reason: Zoi.any() |> Zoi.nullish(),
              snapshot: Zoi.lazy({Snapshot, :schema, []}) |> Zoi.nullish(),
              cancellation: Zoi.lazy({Cancellation, :schema, []}) |> Zoi.nullish()
            },
            coerce: true
          )

  @type kind :: :error | :hibernated | :cancelled
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for sequence terminal data."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds sequence terminal data."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds sequence terminal data or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "session sequence terminal")
end

defmodule Jidoka.Session.Sequence.Result do
  @moduledoc "Result of one ordered session sequence."

  alias Jidoka.Schema
  alias Jidoka.Runtime.Limits
  alias Jidoka.Session.Data
  alias Jidoka.Session.Sequence

  @statuses [:completed, :error, :hibernated, :cancelled]

  @schema Zoi.struct(
            __MODULE__,
            %{
              status: Schema.atom_enum(@statuses),
              session: Zoi.lazy({Data, :schema, []}),
              steps: Zoi.array(Zoi.lazy({Sequence.Step, :schema, []})) |> Zoi.default([]),
              terminal: Zoi.lazy({Sequence.Terminal, :schema, []}) |> Zoi.nullish(),
              limits: Zoi.lazy({Limits.Evidence, :schema, []}) |> Zoi.nullish() |> Zoi.default(nil)
            },
            coerce: true
          )

  @type status :: :completed | :error | :hibernated | :cancelled
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for an ordered session sequence result."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Returns the supported terminal statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds an ordered session sequence result."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds an ordered session sequence result or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "session sequence result")
end

defmodule Jidoka.Session.Sequence do
  @moduledoc "Typed contracts for ordered execution in one Jidoka session."

  alias Jidoka.Turn

  @type input :: [Turn.Request.input()]
end
