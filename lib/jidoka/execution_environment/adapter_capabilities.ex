defmodule Jidoka.ExecutionEnvironment.AdapterCapabilities do
  @moduledoc "Provider-neutral traits declared by one installed environment adapter."

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              adapter_id: Schema.non_empty_string(),
              adapter_version: Schema.non_empty_string(),
              available: Zoi.boolean() |> Zoi.default(true),
              isolations: Zoi.array(Schema.atom_enum([:process, :container, :vm, :microvm])),
              networks: Zoi.array(Schema.atom_enum([:disabled, :restricted, :unrestricted])),
              workspaces: Zoi.array(Schema.atom_enum([:ephemeral, :persistent, :isolated_copy])),
              immutable_image_evidence: Zoi.boolean() |> Zoi.default(false),
              limit_keys: Zoi.array(Schema.non_empty_string()) |> Zoi.default([]),
              checkpoint: Zoi.boolean() |> Zoi.default(false),
              fork: Zoi.boolean() |> Zoi.default(false),
              capability_ids: Zoi.array(Schema.non_empty_string()) |> Zoi.default([]),
              metadata: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the adapter-capability schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a provider-neutral adapter capability declaration."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Schema.parse(@schema, attrs)

  @doc "Builds adapter capabilities and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs), do: Schema.parse!(@schema, attrs, "execution adapter capabilities")

  @doc "Projects capability traits without host executable references."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = capabilities), do: Contract.project(capabilities)
end
