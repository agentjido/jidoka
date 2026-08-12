defmodule Jidoka.ExecutionEnvironment.PolicyRequest do
  @moduledoc """
  Data-only selection of a trusted execution profile.

  Untrusted agent, scenario, or suite data can supply only a profile identifier
  and declared capability identifiers. Backend controls are not accepted.
  """

  alias Jidoka.ExecutionEnvironment.Contract
  alias Jidoka.Schema

  @version 1
  @allowed_keys [:version, :profile_id, :capability_ids, "version", "profile_id", "capability_ids"]

  @schema Zoi.struct(
            __MODULE__,
            %{
              version: Zoi.literal(@version) |> Zoi.default(@version),
              profile_id: Schema.non_empty_string(),
              capability_ids:
                Zoi.array(Schema.non_empty_string()) |> Zoi.default([]) |> Zoi.refine({__MODULE__, :unique, []})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the current schema version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Returns the policy-request schema."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a data-only profile request."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Schema.normalize_attrs(attrs)

    with :ok <- validate_keys(attrs), do: Schema.parse(@schema, attrs)
  end

  @doc "Builds a data-only profile request and raises for invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise ArgumentError, "invalid execution policy request: #{inspect(reason)}"
    end
  end

  @doc "Projects the request into stable JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request), do: Contract.project(request)

  @doc false
  @spec unique([String.t()], keyword()) :: :ok | {:error, String.t()}
  def unique(values, _opts) do
    if Enum.uniq(values) == values, do: :ok, else: {:error, "capability identifiers must be unique"}
  end

  defp validate_keys(attrs) when is_map(attrs) do
    case Map.keys(attrs) -- @allowed_keys do
      [] -> :ok
      keys -> {:error, {:unsupported_execution_policy_keys, Enum.map(keys, &to_string/1)}}
    end
  end

  defp validate_keys(_attrs), do: {:error, :invalid_execution_policy_request}
end
