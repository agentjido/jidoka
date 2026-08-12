defmodule Jidoka.Extension.Registration do
  @moduledoc "Portable trusted registration supplied by an embedding host."

  alias Jidoka.Extension.{CapabilitySet, Identity, PermissionSet}

  @version 1
  @enforce_keys [:identity, :permissions, :capabilities, :modes, :protocol_version]
  defstruct version: @version,
            identity: nil,
            permissions: nil,
            capabilities: nil,
            modes: [],
            protocol_version: 1,
            config_schema_id: nil,
            enabled: true

  @type t :: %__MODULE__{
          version: 1,
          identity: Identity.t(),
          permissions: PermissionSet.t(),
          capabilities: CapabilitySet.t(),
          modes: [:interactive | :automation],
          protocol_version: pos_integer(),
          config_schema_id: String.t() | nil,
          enabled: boolean()
        }

  @doc "Builds a portable registration."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Jidoka.Schema.normalize_attrs(attrs)

    with 1 <- Jidoka.Schema.get_key(attrs, :version, @version),
         {:ok, identity} <- Identity.new(Jidoka.Schema.get_key(attrs, :identity)),
         {:ok, permissions} <- PermissionSet.new(Jidoka.Schema.get_key(attrs, :permissions, [])),
         {:ok, capabilities} <- CapabilitySet.new(Jidoka.Schema.get_key(attrs, :capabilities, [])),
         {:ok, modes} <- normalize_modes(Jidoka.Schema.get_key(attrs, :modes, [:interactive, :automation])),
         protocol when is_integer(protocol) and protocol > 0 <- Jidoka.Schema.get_key(attrs, :protocol_version, 1),
         schema_id <- Jidoka.Schema.get_key(attrs, :config_schema_id),
         true <- is_nil(schema_id) or Identity.valid_id?(schema_id),
         enabled when is_boolean(enabled) <- Jidoka.Schema.get_key(attrs, :enabled, true) do
      {:ok,
       %__MODULE__{
         identity: identity,
         permissions: permissions,
         capabilities: capabilities,
         modes: modes,
         protocol_version: protocol,
         config_schema_id: schema_id,
         enabled: enabled
       }}
    else
      reason -> {:error, {:invalid_extension_registration, reason}}
    end
  end

  @doc "Builds a registration or raises."
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, registration} -> registration
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @doc "Projects the registration without live registry data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = registration) do
    %{
      "version" => registration.version,
      "identity" => Identity.to_map(registration.identity),
      "permissions" => PermissionSet.to_map(registration.permissions),
      "capabilities" => CapabilitySet.to_map(registration.capabilities),
      "modes" => Enum.map(registration.modes, &Atom.to_string/1),
      "protocol_version" => registration.protocol_version,
      "config_schema_id" => registration.config_schema_id,
      "enabled" => registration.enabled
    }
  end

  defp normalize_modes(values) when is_list(values) do
    modes = Enum.map(values, &mode/1) |> Enum.uniq() |> Enum.sort()
    if modes != [] and Enum.all?(modes, &(&1 in [:interactive, :automation])), do: {:ok, modes}, else: {:error, values}
  end

  defp normalize_modes(value), do: {:error, value}
  defp mode("interactive"), do: :interactive
  defp mode("automation"), do: :automation
  defp mode(value), do: value
end
