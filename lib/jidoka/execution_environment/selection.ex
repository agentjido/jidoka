defmodule Jidoka.ExecutionEnvironment.Selection do
  @moduledoc "Validated host selection of one execution environment."

  alias Jidoka.ExecutionEnvironment.AdapterCapabilities
  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.SecurityProfile
  alias Jidoka.ExecutionEnvironment.Validator

  @enforce_keys [:request, :registration, :fingerprint]
  defstruct [:request, :registration, :fingerprint]

  @opaque t :: %__MODULE__{
            request: PolicyRequest.t(),
            registration: Registration.t(),
            fingerprint: String.t()
          }

  @doc false
  @spec build(PolicyRequest.t(), Registration.t()) :: t()
  def build(%PolicyRequest{} = request, %Registration{} = registration) do
    %__MODULE__{
      request: request,
      registration: registration,
      fingerprint: fingerprint(request, registration)
    }
  end

  @doc "Validates that a selection still contains the exact resolved request and registration."
  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(
        %__MODULE__{request: %PolicyRequest{} = request, registration: %Registration{} = registration} = selection
      ) do
    with {:ok, registration} <- validate_registration(registration),
         true <- registration.enabled,
         true <- request.profile_id == registration.profile.profile_id,
         :ok <- Validator.validate_profile(registration.profile, registration.capabilities, request),
         true <- selection.fingerprint == fingerprint(request, registration) do
      {:ok, %__MODULE__{selection | registration: registration}}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, error(:malformed_profile_registration, request.profile_id, reason)}

      false when registration.enabled != true ->
        {:error, error(:disabled_profile, request.profile_id)}

      false when request.profile_id != registration.profile.profile_id ->
        {:error, error(:profile_identity_mismatch, request.profile_id, registration.profile.profile_id)}

      false ->
        {:error, error(:invalid_environment_selection, request.profile_id, :fingerprint_mismatch)}
    end
  end

  def validate(_selection),
    do: {:error, error(:invalid_environment_selection, nil, :invalid_selection_value)}

  @doc "Projects the validated selection without its executable adapter reference."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = selection) do
    %{
      "request" => PolicyRequest.to_map(selection.request),
      "registration" => Registration.to_map(selection.registration),
      "fingerprint" => selection.fingerprint
    }
  end

  defp validate_registration(%Registration{} = registration) do
    with {:ok, profile} <- SecurityProfile.new(Map.from_struct(registration.profile)),
         {:ok, capabilities} <- AdapterCapabilities.new(Map.from_struct(registration.capabilities)),
         {:ok, normalized} <-
           Registration.new(
             profile: profile,
             adapter: registration.adapter,
             capabilities: capabilities,
             enabled: registration.enabled,
             metadata: registration.metadata
           ),
         true <- normalized.fingerprint == registration.fingerprint do
      {:ok, normalized}
    else
      false -> {:error, :registration_fingerprint_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_registration_contract}
    end
  rescue
    exception -> {:error, {:invalid_registration_contract, exception}}
  end

  defp fingerprint(request, registration) do
    Jidoka.ExecutionEnvironment.digest(%{
      "request" => PolicyRequest.to_map(request),
      "registration_fingerprint" => registration.fingerprint
    })
  end

  defp error(code, profile_id, reason \\ nil) do
    details =
      %{profile_id: profile_id}
      |> maybe_put(:reason, reason)

    Error.new(code, "execution environment selection failed", details)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, inspect(value))
end
