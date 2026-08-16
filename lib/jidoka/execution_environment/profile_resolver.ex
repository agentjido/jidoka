defmodule Jidoka.ExecutionEnvironment.ProfileResolver do
  @moduledoc "Host-owned resolver for named trusted execution profiles."

  alias Jidoka.ExecutionEnvironment.Error
  alias Jidoka.ExecutionEnvironment.PolicyRequest
  alias Jidoka.ExecutionEnvironment.Registration
  alias Jidoka.ExecutionEnvironment.Selection

  @callback resolve(profile_id :: String.t(), opts :: keyword()) ::
              {:ok, Registration.t()} | {:error, term()}

  @type resolver :: module() | (String.t(), keyword() -> {:ok, Registration.t()} | {:error, term()})

  @doc "Resolves and validates one data-only policy request through trusted host code."
  @spec resolve(PolicyRequest.t(), resolver(), keyword()) :: {:ok, Selection.t()} | {:error, Error.t()}
  def resolve(%PolicyRequest{} = request, resolver, opts \\ []) do
    with {:ok, %Registration{} = registration} <- call_resolver(resolver, request.profile_id, opts),
         {:ok, %Selection{} = selection} <- request |> Selection.build(registration) |> Selection.validate() do
      {:ok, selection}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :unknown_profile} -> {:error, error(:unknown_profile, request.profile_id)}
      {:error, reason} -> {:error, error(:profile_resolution_failed, request.profile_id, reason)}
      result -> {:error, error(:malformed_profile_registration, request.profile_id, result)}
    end
  end

  defp call_resolver(resolver, profile_id, opts) when is_function(resolver, 2),
    do: safe_call(fn -> resolver.(profile_id, opts) end)

  defp call_resolver(resolver, profile_id, opts) when is_atom(resolver) do
    if function_exported?(resolver, :resolve, 2) do
      safe_call(fn -> resolver.resolve(profile_id, opts) end)
    else
      {:error, :invalid_profile_resolver}
    end
  end

  defp call_resolver(_resolver, _profile_id, _opts), do: {:error, :invalid_profile_resolver}

  defp safe_call(function) do
    function.()
  rescue
    exception -> {:error, {:resolver_exception, exception}}
  catch
    kind, reason -> {:error, {:resolver_failure, {kind, reason}}}
  end

  defp error(code, profile_id, reason \\ nil) do
    details = if is_nil(reason), do: %{profile_id: profile_id}, else: %{profile_id: profile_id, reason: inspect(reason)}
    Error.new(code, "execution profile resolution failed", details)
  end
end
