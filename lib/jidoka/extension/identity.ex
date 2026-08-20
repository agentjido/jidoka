defmodule Jidoka.Extension.Identity do
  @moduledoc "Portable pinned identity for trusted extension code."

  alias Jidoka.ExecutionEnvironment.Contract

  @version 1
  @enforce_keys [:id, :source_type, :source_ref, :release, :content_hash, :trust]
  defstruct version: @version,
            id: nil,
            source_type: nil,
            source_ref: nil,
            release: nil,
            content_hash: nil,
            trust: nil

  @type t :: %__MODULE__{
          version: 1,
          id: String.t(),
          source_type: :built_in | :process,
          source_ref: String.t(),
          release: String.t(),
          content_hash: String.t(),
          trust: :trusted | :untrusted
        }

  @doc "Builds and validates a pinned identity."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)

    identity = %__MODULE__{
      version: value(attrs, :version, @version),
      id: value(attrs, :id),
      source_type: atom_value(value(attrs, :source_type), [:built_in, :process]),
      source_ref: value(attrs, :source_ref),
      release: value(attrs, :release),
      content_hash: value(attrs, :content_hash),
      trust: atom_value(value(attrs, :trust), [:trusted, :untrusted])
    }

    with true <- identity.version == @version,
         true <- valid_id?(identity.id),
         true <- identity.source_type in [:built_in, :process],
         true <- nonempty?(identity.source_ref),
         :ok <- Contract.validate_opaque_ref(identity.source_ref),
         true <- nonempty?(identity.release),
         :ok <- Contract.validate_digest(identity.content_hash, []),
         true <- identity.trust in [:trusted, :untrusted] do
      {:ok, identity}
    else
      reason -> {:error, {:invalid_extension_identity, reason}}
    end
  end

  def new(attrs), do: {:error, {:invalid_extension_identity, attrs}}

  @doc "Builds an identity or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, identity} -> identity
      {:error, reason} -> raise ArgumentError, "invalid extension identity: #{inspect(reason)}"
    end
  end

  @doc "Projects an identity as portable data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = identity), do: Contract.project(identity)

  @doc false
  def valid_id?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$/, value)

  defp value(attrs, key, default \\ nil), do: Jidoka.Schema.get_key(attrs, key, default)
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp atom_value(value, values) when is_binary(value),
    do: Enum.find(values, &(Atom.to_string(&1) == value))

  defp atom_value(value, _values), do: value
end
