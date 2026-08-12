defmodule Jidoka.ExecutionEnvironment.Checkpoint do
  @moduledoc "Portable immutable checkpoint facts for recovery and safe fork."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              checkpoint_ref: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_opaque_ref, []}),
              binding_revision: Zoi.integer() |> Zoi.gte(0),
              profile_digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}),
              evidence_digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}),
              preserves: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []}),
              forkable: Zoi.boolean() |> Zoi.default(false),
              created_at_ms: Zoi.integer() |> Zoi.gte(0)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the checkpoint schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a portable immutable checkpoint."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a checkpoint and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "execution checkpoint")

  @doc "Projects checkpoint facts into stable JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = checkpoint), do: Contract.project(checkpoint)
end
