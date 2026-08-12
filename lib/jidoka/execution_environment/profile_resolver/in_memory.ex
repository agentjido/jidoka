defmodule Jidoka.ExecutionEnvironment.ProfileResolver.InMemory do
  @moduledoc "Deterministic in-memory profile resolver for tests and embedding hosts."

  alias Jidoka.ExecutionEnvironment.Registration

  @enforce_keys [:registrations]
  defstruct [:registrations]

  @type t :: %__MODULE__{registrations: %{String.t() => Registration.t()}}

  @doc "Builds a resolver and rejects duplicate profile identifiers."
  @spec new([Registration.t()]) :: {:ok, t()} | {:error, term()}
  def new(registrations) when is_list(registrations) do
    ids = Enum.map(registrations, & &1.profile.profile_id)

    if Enum.uniq(ids) == ids do
      {:ok, %__MODULE__{registrations: Map.new(registrations, &{&1.profile.profile_id, &1})}}
    else
      {:error, :ambiguous_profile_registration}
    end
  end

  def new(_registrations), do: {:error, :invalid_profile_registrations}

  @doc "Returns a resolver function for `ProfileResolver.resolve/3`."
  @spec resolver(t()) :: (String.t(), keyword() -> {:ok, Registration.t()} | {:error, :unknown_profile})
  def resolver(%__MODULE__{} = resolver) do
    fn profile_id, _opts ->
      case Map.fetch(resolver.registrations, profile_id) do
        {:ok, registration} -> {:ok, registration}
        :error -> {:error, :unknown_profile}
      end
    end
  end
end
