defmodule Jidoka.Credential do
  @moduledoc """
  Credential-reference boundary for authenticated agent operations.

  Jidoka V3 ships credential brokering as a reference contract, not as a
  built-in secret broker. Agents, controls, traces, and tool metadata may carry
  references to a credential, connection, account, or lease. They must not carry
  raw credential values.

  The application or integration layer remains responsible for exchanging a
  reference for a real secret at execution time. That keeps Jidoka useful as the
  agent authoring layer while leaving vault lookup, OAuth refresh, tenant
  routing, and outbound request signing inside the system that owns those
  security guarantees.
  """

  @risks [:unknown, :low, :medium, :high, :critical]

  @derive {Inspect,
           only: [
             :provider,
             :account,
             :actor,
             :tenant,
             :scopes,
             :lease_id,
             :expires_at,
             :risk,
             :confirmation_required,
             :audit_metadata
           ]}
  defstruct provider: nil,
            account: nil,
            actor: nil,
            tenant: nil,
            scopes: [],
            lease_id: nil,
            expires_at: nil,
            risk: :unknown,
            confirmation_required: false,
            audit_metadata: %{}

  @type risk :: :unknown | :low | :medium | :high | :critical
  @type t :: %__MODULE__{
          provider: String.t(),
          account: String.t() | nil,
          actor: String.t() | nil,
          tenant: String.t() | nil,
          scopes: [String.t()],
          lease_id: String.t() | nil,
          expires_at: DateTime.t() | nil,
          risk: risk(),
          confirmation_required: boolean(),
          audit_metadata: map()
        }

  @doc """
  Builds a normalized credential reference.

  `provider` is required. All other fields are descriptive metadata that an
  application-owned broker can use to exchange the reference for a real
  credential outside of the model/provider boundary.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, provider} <- required_string(attrs, :provider),
         {:ok, account} <- optional_string(attrs, :account),
         {:ok, actor} <- optional_string(attrs, :actor),
         {:ok, tenant} <- optional_string(attrs, :tenant),
         {:ok, scopes} <- normalize_scopes(value(attrs, :scopes, [])),
         {:ok, lease_id} <- optional_string(attrs, :lease_id),
         {:ok, expires_at} <- normalize_expires_at(value(attrs, :expires_at)),
         {:ok, risk} <- normalize_risk(value(attrs, :risk, :unknown)),
         {:ok, confirmation_required} <-
           normalize_confirmation_required(value(attrs, :confirmation_required, false)),
         {:ok, audit_metadata} <- normalize_audit_metadata(value(attrs, :audit_metadata, %{})) do
      {:ok,
       %__MODULE__{
         provider: provider,
         account: account,
         actor: actor,
         tenant: tenant,
         scopes: scopes,
         lease_id: lease_id,
         expires_at: expires_at,
         risk: risk,
         confirmation_required: confirmation_required,
         audit_metadata: audit_metadata
       }}
    end
  end

  def new(attrs), do: {:error, invalid(:credential, attrs, :expected_map)}

  @doc """
  Builds a normalized credential reference or raises on invalid input.
  """
  @spec new!(keyword() | map()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, credential} -> credential
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the accepted risk levels for credential references.
  """
  @spec risks() :: [risk()]
  def risks, do: @risks

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp required_string(attrs, key) do
    case optional_string(attrs, key) do
      {:ok, nil} -> {:error, invalid(key, nil, :required)}
      other -> other
    end
  end

  defp optional_string(attrs, key) do
    case value(attrs, key) do
      nil -> {:ok, nil}
      value when is_atom(value) -> normalize_string(key, Atom.to_string(value))
      value when is_binary(value) -> normalize_string(key, value)
      value -> {:error, invalid(key, value, :expected_string)}
    end
  end

  defp normalize_string(key, value) do
    case String.trim(value) do
      "" -> {:error, invalid(key, value, :empty)}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_scopes(nil), do: {:ok, []}

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.reduce_while({:ok, []}, fn scope, {:ok, acc} ->
      case normalize_scope(scope) do
        {:ok, scope} -> {:cont, {:ok, acc ++ [scope]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, scopes} -> {:ok, Enum.uniq(scopes)}
      other -> other
    end
  end

  defp normalize_scopes(scopes), do: {:error, invalid(:scopes, scopes, :expected_list)}

  defp normalize_scope(scope) when is_atom(scope), do: normalize_scope(Atom.to_string(scope))

  defp normalize_scope(scope) when is_binary(scope) do
    case String.trim(scope) do
      "" -> {:error, invalid(:scopes, scope, :empty_scope)}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_scope(scope), do: {:error, invalid(:scopes, scope, :expected_scope)}

  defp normalize_expires_at(nil), do: {:ok, nil}
  defp normalize_expires_at(%DateTime{} = expires_at), do: {:ok, expires_at}

  defp normalize_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> {:ok, expires_at}
      {:error, _reason} -> {:error, invalid(:expires_at, value, :invalid_datetime)}
    end
  end

  defp normalize_expires_at(value), do: {:error, invalid(:expires_at, value, :expected_datetime)}

  defp normalize_risk(value) when value in @risks, do: {:ok, value}

  defp normalize_risk(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Enum.find_value(@risks, {:error, invalid(:risk, value, :invalid_risk)}, fn risk ->
      if Atom.to_string(risk) == normalized, do: {:ok, risk}
    end)
  end

  defp normalize_risk(value), do: {:error, invalid(:risk, value, :invalid_risk)}

  defp normalize_confirmation_required(value) when is_boolean(value), do: {:ok, value}

  defp normalize_confirmation_required(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, invalid(:confirmation_required, value, :expected_boolean)}
    end
  end

  defp normalize_confirmation_required(value),
    do: {:error, invalid(:confirmation_required, value, :expected_boolean)}

  defp normalize_audit_metadata(metadata) when is_map(metadata), do: {:ok, metadata}

  defp normalize_audit_metadata(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata) do
      {:ok, Map.new(metadata)}
    else
      {:error, invalid(:audit_metadata, metadata, :expected_map)}
    end
  end

  defp normalize_audit_metadata(metadata), do: {:error, invalid(:audit_metadata, metadata, :expected_map)}

  defp invalid(field, value, reason) do
    Jidoka.Error.validation_error("Invalid credential reference.",
      field: field,
      value: value,
      details: %{reason: reason}
    )
  end
end
