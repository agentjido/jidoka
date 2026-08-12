defmodule Jidoka.ExecutionEnvironment.SecurityProfile do
  @moduledoc "Trusted immutable requirements for one execution profile."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1
  @isolations [:process, :container, :vm, :microvm]
  @networks [:disabled, :restricted, :unrestricted]
  @workspaces [:ephemeral, :persistent, :isolated_copy]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              profile_id: Schema.non_empty_string(),
              revision: Zoi.integer() |> Zoi.gte(1),
              digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}),
              adapter_id: Schema.non_empty_string(),
              required_isolation: Schema.atom_enum(@isolations),
              required_network: Schema.atom_enum(@networks),
              required_workspace: Schema.atom_enum(@workspaces),
              required_image_digest:
                Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}) |> Zoi.nullish(),
              maximum_limits: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_limits, []}),
              checkpoint_required: Zoi.boolean() |> Zoi.default(false),
              fork_required: Zoi.boolean() |> Zoi.default(false),
              retention: Schema.atom_enum([:ephemeral, :durable]) |> Zoi.default(:ephemeral),
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

  @doc "Returns the trusted security-profile schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a trusted immutable security profile."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds a security profile and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "execution security profile")

  @doc "Projects the profile without provider-private or credential fields."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = profile), do: Contract.project(profile)
end
