defmodule Jidoka.Extension.Binding do
  @moduledoc "Portable durable result of trusted extension resolution."

  alias Jidoka.Extension.{CapabilitySet, Identity, PermissionSet, Registration, Request}

  @version 1
  @enforce_keys [:request_id, :instance_key, :identity, :permissions, :capabilities, :mode, :protocol_version]
  defstruct version: @version,
            request_id: nil,
            instance_key: nil,
            identity: nil,
            permissions: nil,
            capabilities: nil,
            mode: nil,
            protocol_version: nil

  @type t :: %__MODULE__{
          version: 1,
          request_id: String.t(),
          instance_key: String.t(),
          identity: Identity.t(),
          permissions: PermissionSet.t(),
          capabilities: CapabilitySet.t(),
          mode: :interactive | :automation,
          protocol_version: pos_integer()
        }

  @doc "Creates a portable binding from a request and trusted registration."
  @spec from(Request.t(), Registration.t(), :interactive | :automation) :: t()
  def from(%Request{} = request, %Registration{} = registration, mode) do
    %__MODULE__{
      request_id: request.id,
      instance_key: Request.instance_key(request),
      identity: registration.identity,
      permissions: registration.permissions,
      capabilities: registration.capabilities,
      mode: mode,
      protocol_version: registration.protocol_version
    }
  end

  @doc "Projects a binding as stable JSON-safe data."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = binding) do
    %{
      "version" => binding.version,
      "request_id" => binding.request_id,
      "instance_key" => binding.instance_key,
      "identity" => Identity.to_map(binding.identity),
      "permissions" => PermissionSet.to_map(binding.permissions),
      "capabilities" => CapabilitySet.to_map(binding.capabilities),
      "mode" => Atom.to_string(binding.mode),
      "protocol_version" => binding.protocol_version
    }
  end
end
