defmodule Jidoka.ExecutionEnvironment.Registration do
  @moduledoc "Host-owned registration for one trusted profile and installed adapter."

  alias Jidoka.ExecutionEnvironment
  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  @enforce_keys [:profile, :adapter, :capabilities, :fingerprint]
  defstruct [:profile, :adapter, :capabilities, :fingerprint, enabled: true, metadata: %{}]

  @type t :: %__MODULE__{
          profile: SecurityProfile.t(),
          adapter: module(),
          capabilities: AdapterCapabilities.t(),
          fingerprint: String.t(),
          enabled: boolean(),
          metadata: map()
        }

  @doc "Builds a trusted host registration."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    with %SecurityProfile{} = profile <- Keyword.get(attrs, :profile),
         adapter when is_atom(adapter) <- Keyword.get(attrs, :adapter),
         %AdapterCapabilities{} = capabilities <- Keyword.get(attrs, :capabilities),
         true <- profile.adapter_id == capabilities.adapter_id do
      enabled = Keyword.get(attrs, :enabled, true)
      metadata = Keyword.get(attrs, :metadata, %{})

      fingerprint =
        ExecutionEnvironment.digest(%{
          profile: SecurityProfile.to_map(profile),
          capabilities: AdapterCapabilities.to_map(capabilities),
          enabled: enabled
        })

      {:ok,
       %__MODULE__{
         profile: profile,
         adapter: adapter,
         capabilities: capabilities,
         fingerprint: fingerprint,
         enabled: enabled,
         metadata: metadata
       }}
    else
      false -> {:error, :adapter_profile_identity_mismatch}
      _invalid -> {:error, :invalid_execution_environment_registration}
    end
  end

  def new(_attrs), do: {:error, :invalid_execution_environment_registration}

  @doc "Builds a trusted registration and raises for invalid input."
  @spec new!(keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, registration} -> registration
      {:error, reason} -> raise ArgumentError, "invalid execution registration: #{inspect(reason)}"
    end
  end

  @doc "Projects stable registration identity without the executable adapter reference."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = registration) do
    %{
      "profile" => SecurityProfile.to_map(registration.profile),
      "capabilities" => AdapterCapabilities.to_map(registration.capabilities),
      "fingerprint" => registration.fingerprint,
      "enabled" => registration.enabled
    }
  end
end
