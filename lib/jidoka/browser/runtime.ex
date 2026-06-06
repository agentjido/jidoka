defmodule Jidoka.Browser.Runtime do
  @moduledoc false

  @blocked_hosts MapSet.new(["localhost", "0.0.0.0", "127.0.0.1", "::1"])
  @browser_actions %{
    search_web: Jido.Browser.Actions.SearchWeb,
    read_page: Jido.Browser.Actions.ReadPage,
    snapshot_url: Jido.Browser.Actions.SnapshotUrl
  }

  @spec action_module(:search_web | :read_page | :snapshot_url) :: module()
  def action_module(operation) do
    overrides = Application.get_env(:jidoka, :browser_actions, %{})
    Map.get(overrides, operation, Map.fetch!(@browser_actions, operation))
  end

  @spec max_results() :: pos_integer()
  def max_results do
    Application.get_env(:jidoka, :browser_max_results, 10)
  end

  @spec max_content_chars() :: pos_integer()
  def max_content_chars do
    Application.get_env(:jidoka, :browser_max_content_chars, 20_000)
  end

  @spec delegate(module(), map(), map()) :: {:ok, term()} | {:error, term()}
  def delegate(action_module, params, context) do
    with {:module, module} <- Code.ensure_loaded(action_module),
         true <- function_exported?(module, :run, 2) do
      module.run(params, context)
    else
      _reason ->
        {:error,
         Jidoka.Error.execution_error("Browser action is not available.",
           phase: :browser,
           details: %{
             reason: :missing_browser_action,
             action: inspect(action_module)
           }
         )}
    end
  end

  @spec clamp_search_results(term()) :: pos_integer()
  def clamp_search_results(value) when is_integer(value) do
    value
    |> max(1)
    |> min(max_results())
  end

  def clamp_search_results(_value), do: max_results()

  @spec clamp_content_chars(term()) :: pos_integer()
  def clamp_content_chars(value) when is_integer(value) do
    value
    |> max(1)
    |> min(max_content_chars())
  end

  def clamp_content_chars(_value), do: max_content_chars()

  @spec truncate_content(map(), pos_integer()) :: map()
  def truncate_content(%{} = result, max_chars) do
    result
    |> Map.update(:content, nil, &truncate_text(&1, max_chars))
    |> Map.update("content", nil, &truncate_text(&1, max_chars))
  end

  @spec validate_public_url(term()) :: :ok | {:error, Exception.t()}
  def validate_public_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      uri.scheme not in ["http", "https"] ->
        invalid_url(url, "URL must use http or https.")

      is_nil(uri.host) or String.trim(uri.host) == "" ->
        invalid_url(url, "URL must include a host.")

      blocked_host?(uri.host) ->
        invalid_url(url, "Local, loopback, and private network URLs are not allowed.")

      true ->
        :ok
    end
  end

  def validate_public_url(url), do: invalid_url(url, "URL must be a string.")

  @spec validate_allowlist(term(), map(), String.t()) :: :ok | {:error, Exception.t()}
  def validate_allowlist(url, context, operation_name) do
    allowlist = allowlist_for(context, operation_name)

    if allowlist == [] or allowed_url?(url, allowlist) do
      :ok
    else
      {:error,
       Jidoka.Error.validation_error("URL is not allowed for this browser tool.",
         field: :url,
         value: url,
         details: %{
           operation: operation_name,
           reason: :browser_url_not_allowed,
           allow: allowlist
         }
       )}
    end
  end

  @spec normalize_browser_error(atom(), term()) :: Exception.t()
  def normalize_browser_error(operation, reason) do
    Jidoka.Error.execution_error("Browser #{operation} failed.",
      phase: :browser,
      details: %{
        operation: operation,
        target: :jido_browser,
        cause: reason
      }
    )
  end

  defp allowlist_for(%Jidoka.Context{} = context, operation_name) do
    context
    |> Jidoka.Context.get_runtime(:jidoka_spec)
    |> allowlist_for(operation_name)
  end

  defp allowlist_for(%{operations: operations}, operation_name) do
    operations
    |> Enum.find(&(&1.name == operation_name))
    |> case do
      %{metadata: metadata} -> Map.get(metadata, "allow", Map.get(metadata, :allow, []))
      _operation -> []
    end
  end

  defp allowlist_for(_context, _operation_name), do: []

  defp allowed_url?(url, allowlist) when is_binary(url) do
    uri = URI.parse(String.trim(url))
    host = normalize_host(uri.host)

    Enum.any?(allowlist, fn allowed ->
      allowed = to_string(allowed) |> String.trim()
      allowed_uri = URI.parse(allowed)

      cond do
        allowed_uri.scheme in ["http", "https"] and is_binary(allowed_uri.host) ->
          String.starts_with?(url, allowed) or normalize_host(allowed_uri.host) == host

        allowed != "" ->
          normalize_host(allowed) == host

        true ->
          false
      end
    end)
  end

  defp allowed_url?(_url, _allowlist), do: false

  defp truncate_text(content, max_chars) when is_binary(content) do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <> "\n\n[Content truncated by Jidoka.Browser.]"
    else
      content
    end
  end

  defp truncate_text(content, _max_chars), do: content

  defp invalid_url(url, message) do
    {:error,
     Jidoka.Error.validation_error(message,
       field: :url,
       value: url,
       details: %{operation: :browser, reason: :invalid_url, cause: url}
     )}
  end

  defp blocked_host?(host) when is_binary(host) do
    normalized = normalize_host(host)

    MapSet.member?(@blocked_hosts, normalized) or
      String.ends_with?(normalized, ".localhost") or
      private_ipv4?(normalized) or
      private_ipv6?(normalized) or
      unverified_or_private_host?(normalized)
  end

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp unverified_or_private_host?(host) do
    case resolve_host_addresses(host) do
      {:ok, addresses} -> Enum.any?(addresses, &private_address?/1)
      {:error, _reason} -> true
    end
  end

  defp resolve_host_addresses(host) do
    resolver = Application.get_env(:jidoka, :dns_resolver, &:inet.getaddrs/2)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case resolver.(String.to_charlist(host), family) do
          {:ok, values} when is_list(values) -> values
          _other -> []
        end
      end)
      |> Enum.uniq()

    if addresses == [] do
      {:error, :not_resolved}
    else
      {:ok, addresses}
    end
  rescue
    _error -> {:error, :not_resolved}
  end

  defp private_ipv4?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 4 -> private_ipv4_address?(address)
      _other -> false
    end
  end

  defp private_ipv6?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_ipv6_address?(address)
      _other -> false
    end
  end

  defp private_ipv6_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ipv6_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ipv6_address?({0, 0, 0, 0, 0, ipv4_marker, high, low})
       when ipv4_marker in [0, 0xFFFF] do
    {a, b, c, d} = ipv4_octets(high, low)
    private_ipv4_address?({a, b, c, d})
  end

  defp private_ipv6_address?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF, do: true
  defp private_ipv6_address?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEFF, do: true
  defp private_ipv6_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00 and first <= 0xFFFF, do: true
  defp private_ipv6_address?(_address), do: false

  defp private_ipv4_address?({10, _, _, _}), do: true
  defp private_ipv4_address?({127, _, _, _}), do: true
  defp private_ipv4_address?({169, 254, _, _}), do: true
  defp private_ipv4_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_ipv4_address?({192, 168, _, _}), do: true
  defp private_ipv4_address?({0, _, _, _}), do: true
  defp private_ipv4_address?(_address), do: false

  defp private_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    private_ipv4_address?(address)
  end

  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_address?({0, 0, 0, 0, 0, ipv4_marker, high, low})
       when ipv4_marker in [0, 0xFFFF] do
    {a, b, c, d} = ipv4_octets(high, low)
    private_ipv4_address?({a, b, c, d})
  end

  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF,
    do: true

  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEFF,
    do: true

  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00 and first <= 0xFFFF,
    do: true

  defp private_address?(_address), do: false

  defp ipv4_octets(high, low) do
    {
      div(high, 256),
      rem(high, 256),
      div(low, 256),
      rem(low, 256)
    }
  end
end
