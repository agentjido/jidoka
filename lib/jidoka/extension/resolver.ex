defmodule Jidoka.Extension.Resolver do
  @moduledoc "Fail-closed resolver from inert requests to trusted portable bindings."

  alias Jidoka.Extension.{Binding, Error, PermissionSet, Registration, Request}

  @type registry :: map() | (String.t() -> term()) | module()

  @doc "Resolves an ordered request list through an injected trusted registry."
  @spec resolve_all([Request.t()], registry(), :interactive | :automation, keyword()) ::
          {:ok, [Binding.t()]} | {:error, Error.t()}
  def resolve_all(requests, registry, mode, opts \\ []) when mode in [:interactive, :automation] do
    requests
    |> Enum.filter(& &1.enabled)
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, bindings} ->
      case resolve(request, registry, mode, opts) do
        {:ok, binding} -> {:cont, {:ok, [binding | bindings]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      error -> error
    end
  end

  @doc "Resolves one request and validates trust, mode, permission, config, and resume identity."
  @spec resolve(Request.t(), registry(), :interactive | :automation, keyword()) ::
          {:ok, Binding.t()} | {:error, Error.t()}
  def resolve(%Request{} = request, registry, mode, opts \\ []) do
    with {:ok, entry} <- lookup(registry, request.id),
         {:ok, registration, config_validator} <- normalize_entry(entry),
         :ok <- validate_registration(request, registration, mode, opts),
         :ok <- validate_config(config_validator, request.config),
         binding = Binding.from(request, registration, mode),
         :ok <- validate_resume(Keyword.get(opts, :resume_binding), binding) do
      {:ok, binding}
    else
      {:error, code} -> {:error, Error.new(code, %{extension_id: request.id})}
      {:error, code, details} -> {:error, Error.new(code, Map.put(details, :extension_id, request.id))}
    end
  end

  @doc "Checks that a durable binding still has the same identity and grants."
  @spec validate_resume(Binding.t() | nil, Binding.t()) :: :ok | {:error, atom(), map()}
  def validate_resume(nil, _binding), do: :ok

  def validate_resume(%Binding{} = prior, %Binding{} = current) do
    if Binding.to_map(prior) == Binding.to_map(current) do
      :ok
    else
      {:error, :extension_binding_changed, %{instance_key: current.instance_key}}
    end
  end

  defp lookup(registry, id) when is_map(registry) do
    case Map.fetch(registry, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_extension}
    end
  end

  defp lookup(registry, id) when is_function(registry, 1), do: safe_lookup(fn -> registry.(id) end)

  defp lookup(registry, id) when is_atom(registry) do
    if function_exported?(registry, :lookup, 1),
      do: safe_lookup(fn -> registry.lookup(id) end),
      else: {:error, :invalid_extension_registry}
  end

  defp lookup(_registry, _id), do: {:error, :invalid_extension_registry}

  defp safe_lookup(function) do
    case function.() do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_extension}
      {:error, reason} -> {:error, :extension_registry_failure, %{reason: inspect(reason)}}
      entry -> {:ok, entry}
    end
  rescue
    exception -> {:error, :extension_registry_failure, %{reason: Exception.message(exception)}}
  end

  defp normalize_entry(%Registration{} = registration), do: {:ok, registration, nil}

  defp normalize_entry(%{registration: %Registration{} = registration} = entry),
    do: {:ok, registration, Map.get(entry, :validate_config)}

  defp normalize_entry([_first, _second | _rest]), do: {:error, :duplicate_extension_registration}
  defp normalize_entry(_entry), do: {:error, :malformed_extension_registration}

  defp validate_registration(request, registration, mode, opts) do
    allowed = Keyword.get(opts, :allowed_permissions, :all)

    cond do
      registration.identity.id != request.id -> {:error, :extension_identity_mismatch}
      not registration.enabled -> {:error, :extension_disabled}
      registration.identity.trust != :trusted -> {:error, :extension_untrusted}
      mode not in registration.modes -> {:error, :extension_mode_not_supported}
      request.mode != :both and request.mode != mode -> {:error, :extension_request_mode_mismatch}
      not PermissionSet.subset?(registration.permissions, allowed) -> {:error, :extension_permission_denied}
      true -> :ok
    end
  end

  defp validate_config(nil, _config), do: :ok

  defp validate_config(validator, config) when is_function(validator, 1) do
    case validator.(config) do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, :extension_config_invalid, %{reason: inspect(reason)}}
      other -> {:error, :extension_config_invalid, %{reason: inspect(other)}}
    end
  rescue
    exception -> {:error, :extension_config_invalid, %{reason: Exception.message(exception)}}
  end

  defp validate_config(_validator, _config), do: {:error, :invalid_extension_config_validator}
end
