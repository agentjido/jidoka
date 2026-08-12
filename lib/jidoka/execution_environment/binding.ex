defmodule Jidoka.ExecutionEnvironment.Binding do
  @moduledoc "Portable durable identity for an execution environment."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1
  @states [:opened, :available, :acquired, :closed, :cleaned]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              adapter_id: Schema.non_empty_string(),
              adapter_version: Schema.non_empty_string(),
              profile_id: Schema.non_empty_string(),
              profile_digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}),
              resource_ref: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_opaque_ref, []}),
              revision: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
              state: Schema.atom_enum(@states) |> Zoi.default(:opened),
              metadata: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the portable binding schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a portable execution binding."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a portable binding and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "execution binding")

  @doc "Projects a durable binding into stable JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = binding), do: Contract.project(binding)
end
