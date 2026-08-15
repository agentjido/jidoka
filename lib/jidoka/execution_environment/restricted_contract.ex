defmodule Jidoka.ExecutionEnvironment.RestrictedContract do
  @moduledoc """
  Additive v0.1 contracts for the restricted local execution path.

  These types describe explicit roots, environment allowlists, credential
  references, network policy, resource limits, cancellation, deadlines, and
  cleanup evidence. Unknown bounded fields remain data and never grant
  authority.
  """

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1
  @root_kinds [:workspace, :toolchain, :artifact, :temporary]
  @network_scopes [:loopback, :external]
  @network_decisions [:allow, :deny]
  @cleanup_statuses [:clean, :failed, :unknown]

  @type t :: %{
          optional(:version) => pos_integer(),
          required(:profile_id) => String.t(),
          required(:roots) => [map()],
          required(:environment) => map(),
          optional(:credentials) => [map()],
          optional(:network) => [map()],
          optional(:resources) => map(),
          required(:cancellation) => map(),
          required(:deadline_ms) => pos_integer(),
          required(:cleanup) => map(),
          optional(:unknown) => map()
        }

  @doc "Returns the restricted-contract schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the declared root kinds for the v0.1 restricted path."
  @spec root_kinds() :: [atom()]
  def root_kinds, do: @root_kinds

  @doc "Returns the restricted-contract schema."
  @spec schema() :: Zoi.schema()
  def schema do
    Zoi.map(
      %{
        version: Zoi.literal(@version) |> Zoi.default(@version),
        profile_id: Schema.non_empty_string(),
        roots: Zoi.array(root_schema()) |> Zoi.min(1),
        environment: environment_schema(),
        credentials: Zoi.array(credential_schema()) |> Zoi.default([]),
        network: Zoi.array(network_schema()) |> Zoi.default([]),
        resources: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_limits, []}),
        cancellation: cancellation_schema(),
        deadline_ms: Zoi.integer() |> Zoi.gte(1),
        cleanup: cleanup_schema(),
        unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
      },
      coerce: true
    )
  end

  @doc "Builds one restricted v0.1 execution contract."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs), do: Zoi.parse(schema(), Schema.normalize_attrs(attrs))

  @doc "Builds one restricted v0.1 execution contract and raises on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "invalid restricted execution contract: #{inspect(reason)}"
    end
  end

  @doc "Returns the compatibility identity for the v0.1 restricted contract."
  @spec compatibility() :: map()
  def compatibility do
    %{
      "contract" => "jidoka.execution.restricted",
      "version" => @version,
      "release_target" => "v0.1",
      "policy_outcomes" => Enum.map(Jidoka.Policy.Decision.outcomes(), &Atom.to_string/1),
      "root_kinds" => Enum.map(@root_kinds, &Atom.to_string/1),
      "network_scopes" => Enum.map(@network_scopes, &Atom.to_string/1)
    }
  end

  @doc "Validates that a contract satisfies the v0.1 restricted compatibility matrix."
  @spec compatible?(t()) :: :ok | {:error, term()}
  def compatible?(contract) when is_map(contract) do
    kinds =
      contract
      |> field(:roots)
      |> List.wrap()
      |> Enum.map(&root_kind/1)
      |> Enum.sort()

    missing = @root_kinds -- kinds

    cond do
      missing != [] ->
        {:error, {:missing_required_roots, missing}}

      field(field(contract, :environment), :private_home) != true ->
        {:error, :private_home_required}

      field(field(contract, :cancellation), :enabled) != true ->
        {:error, :cancellation_required}

      true ->
        :ok
    end
  end

  defp root_schema do
    Zoi.map(%{
      kind: Schema.atom_enum(@root_kinds),
      digest: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_digest, []}),
      writable: Zoi.boolean(),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end

  defp environment_schema do
    Zoi.map(%{
      allowlist: Zoi.array(Schema.non_empty_string()),
      private_home: Zoi.boolean(),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end

  defp credential_schema do
    Zoi.map(%{
      provider: Schema.non_empty_string(),
      source: Schema.non_empty_string(),
      reference: Schema.non_empty_string() |> Zoi.refine({Contract, :validate_opaque_ref, []}),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end

  defp network_schema do
    Zoi.map(%{
      scope: Schema.atom_enum(@network_scopes),
      decision: Schema.atom_enum(@network_decisions),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end

  defp cancellation_schema do
    Zoi.map(%{
      enabled: Zoi.boolean(),
      deadline_ms: Zoi.integer() |> Zoi.gte(1) |> Zoi.nullish(),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end

  defp root_kind(root), do: field(root, :kind)

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_other, _key), do: nil

  defp cleanup_schema do
    Zoi.map(%{
      status: Schema.atom_enum(@cleanup_statuses),
      child_processes: Zoi.integer() |> Zoi.gte(0),
      unknown: Zoi.map() |> Zoi.default(%{}) |> Zoi.refine({Contract, :validate_safe_map, []})
    })
  end
end
