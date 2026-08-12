defmodule Jidoka.ExecutionEnvironment.EnforcementEvidence do
  @moduledoc "Confirmed execution controls observed from an environment adapter."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1
  @statuses [:confirmed, :partial, :unknown, :unsupported]
  @isolations [:unknown, :none, :process, :container, :vm, :microvm]
  @networks [:unknown, :disabled, :restricted, :unrestricted]
  @workspaces [:unknown, :ephemeral, :persistent, :isolated_copy]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              status: Schema.atom_enum(@statuses),
              adapter_id: Schema.non_empty_string(),
              backend: Schema.non_empty_string(),
              isolation: Schema.atom_enum(@isolations) |> Zoi.default(:unknown),
              network: Schema.atom_enum(@networks) |> Zoi.default(:unknown),
              workspace: Schema.atom_enum(@workspaces) |> Zoi.default(:unknown),
              image_digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}) |> Zoi.nullish(),
              applied_limits: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_limits, []}),
              checkpoint: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []}),
              observed_at_ms: Zoi.integer() |> Zoi.gte(0),
              attestation_ref:
                Schema.non_empty_string() |> Zoi.refine({Contract, :validate_opaque_ref, []}) |> Zoi.nullish(),
              facts: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the enforcement-evidence schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds confirmed or explicitly unknown enforcement evidence."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds enforcement evidence and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "execution enforcement evidence")

  @doc "Projects confirmed evidence without provider-private or credential fields."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evidence), do: Contract.project(evidence)
end
