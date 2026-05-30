defmodule Jidoka.Eval.Run do
  @moduledoc "Result of running a `Jidoka.Eval.Case`."

  alias Jidoka.Schema
  alias Jidoka.Turn

  @statuses [:passed, :failed, :error]

  @schema Zoi.struct(
            __MODULE__,
            %{
              case_id: Schema.non_empty_string(),
              status: Schema.atom_enum(@statuses),
              result: Zoi.lazy({Turn.Result, :schema, []}) |> Zoi.nullish(),
              error: Zoi.any() |> Zoi.nullish(),
              assertions: Zoi.array(Zoi.map()) |> Zoi.default([]),
              observations: Zoi.map() |> Zoi.default(%{}),
              metadata: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type status :: :passed | :failed | :error
  @type assertion :: %{
          required(:name) => atom(),
          required(:status) => :passed | :failed,
          optional(:expected) => term(),
          optional(:actual) => term()
        }
  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "eval run")
end
