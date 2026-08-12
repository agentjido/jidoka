defmodule Jidoka.ExecutionEnvironment.Validator do
  @moduledoc "Fail-closed compatibility checks for profiles and confirmed evidence."

  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.EnforcementEvidence
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.SecurityProfile

  @isolation_rank %{none: 0, process: 1, container: 2, vm: 3, microvm: 4}

  @doc "Checks a trusted profile against declared adapter capabilities."
  @spec validate_profile(SecurityProfile.t(), AdapterCapabilities.t(), PolicyRequest.t()) ::
          :ok | {:error, Error.t()}
  def validate_profile(%SecurityProfile{} = profile, %AdapterCapabilities{} = capabilities, %PolicyRequest{} = request) do
    checks = [
      {:adapter_available, capabilities.available},
      {:adapter_identity, profile.adapter_id == capabilities.adapter_id},
      {:isolation, profile.required_isolation in capabilities.isolations},
      {:network, profile.required_network in capabilities.networks},
      {:workspace, profile.required_workspace in capabilities.workspaces},
      {:image_digest, is_nil(profile.required_image_digest) or capabilities.immutable_image_evidence},
      {:limits, limit_keys(profile.maximum_limits) -- capabilities.limit_keys == []},
      {:checkpoint, not profile.checkpoint_required or capabilities.checkpoint},
      {:fork, not profile.fork_required or capabilities.fork},
      {:capability_ids, request.capability_ids -- capabilities.capability_ids == []}
    ]

    require_checks(checks, :insufficient_adapter_capability, profile.profile_id)
  end

  @doc "Checks confirmed evidence against every trusted profile requirement."
  @spec validate_evidence(SecurityProfile.t(), EnforcementEvidence.t()) :: :ok | {:error, Error.t()}
  def validate_evidence(%SecurityProfile{} = profile, %EnforcementEvidence{} = evidence) do
    checks = [
      {:status, evidence.status == :confirmed},
      {:adapter_identity, evidence.adapter_id == profile.adapter_id},
      {:isolation, isolation_at_least?(evidence.isolation, profile.required_isolation)},
      {:network, network_satisfies?(evidence.network, profile.required_network)},
      {:workspace, evidence.workspace == profile.required_workspace},
      {:image_digest, is_nil(profile.required_image_digest) or evidence.image_digest == profile.required_image_digest},
      {:limits, limits_satisfy?(evidence.applied_limits, profile.maximum_limits)},
      {:checkpoint, not profile.checkpoint_required or fact?(evidence.checkpoint, "supported")},
      {:fork, not profile.fork_required or fact?(evidence.checkpoint, "forkable")}
    ]

    require_checks(checks, :execution_environment_unenforced, profile.profile_id)
  end

  defp require_checks(checks, code, profile_id) do
    case Enum.find(checks, fn {_dimension, valid?} -> not valid? end) do
      nil ->
        :ok

      {dimension, false} ->
        {:error,
         Error.new(code, "execution environment requirement is not satisfied", %{
           profile_id: profile_id,
           dimension: dimension
         })}
    end
  end

  defp limit_keys(map), do: Enum.map(Map.keys(map), &to_string/1)

  defp isolation_at_least?(actual, required),
    do: Map.get(@isolation_rank, actual, -1) >= Map.get(@isolation_rank, required, 99)

  defp network_satisfies?(:disabled, _required), do: true
  defp network_satisfies?(:restricted, required), do: required in [:restricted, :unrestricted]
  defp network_satisfies?(:unrestricted, :unrestricted), do: true
  defp network_satisfies?(_actual, _required), do: false

  defp limits_satisfy?(applied, maximum) do
    Enum.all?(maximum, fn {key, ceiling} ->
      case Map.get(applied, key, Map.get(applied, to_string(key))) do
        value when is_number(value) and is_number(ceiling) -> value <= ceiling
        _value -> false
      end
    end)
  end

  defp fact?(map, "supported"), do: Map.get(map, "supported", Map.get(map, :supported)) == true
  defp fact?(map, "forkable"), do: Map.get(map, "forkable", Map.get(map, :forkable)) == true
end
