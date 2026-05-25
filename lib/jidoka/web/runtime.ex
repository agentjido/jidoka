defmodule Jidoka.Web.Runtime do
  @moduledoc false

  @blocked_hosts MapSet.new(["localhost", "0.0.0.0", "127.0.0.1", "::1"])

  @spec clamp_search_results(term()) :: pos_integer()
  def clamp_search_results(value) when is_integer(value) do
    value
    |> max(1)
    |> min(Jidoka.Web.Config.max_results())
  end

  def clamp_search_results(_value), do: Jidoka.Web.Config.max_results()

  @spec clamp_content_chars(term()) :: pos_integer()
  def clamp_content_chars(value) when is_integer(value) do
    value
    |> max(1)
    |> min(Jidoka.Web.Config.max_content_chars())
  end

  def clamp_content_chars(_value), do: Jidoka.Web.Config.max_content_chars()

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

  @spec normalize_browser_error(atom(), term()) :: Exception.t()
  def normalize_browser_error(operation, reason) do
    Jidoka.Error.execution_error("Web #{operation} failed.",
      phase: :web,
      details: %{
        operation: operation,
        target: :jido_browser,
        cause: reason
      }
    )
  end

  defp truncate_text(content, max_chars) when is_binary(content) do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <> "\n\n[Content truncated by Jidoka.Web.]"
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
       details: %{operation: :web, reason: :invalid_url, cause: url}
     )}
  end

  defp blocked_host?(host) when is_binary(host) do
    normalized =
      host
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.downcase()

    MapSet.member?(@blocked_hosts, normalized) or
      String.ends_with?(normalized, ".localhost") or
      private_ipv4?(normalized) or
      private_ipv6?(normalized) or
      unverified_or_private_host?(normalized)
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
      _ -> false
    end
  end

  defp private_ipv6?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} ->
        true

      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} ->
        true

      {:ok, {0, 0, 0, 0, 0, ipv4_marker, high, low}} when ipv4_marker in [0, 0xFFFF] ->
        {a, b, c, d} = ipv4_octets(high, low)
        private_ipv4_address?({a, b, c, d})

      {:ok, {first, _, _, _, _, _, _, _}} when first >= 0xFC00 and first <= 0xFDFF ->
        true

      {:ok, {first, _, _, _, _, _, _, _}} when first >= 0xFE80 and first <= 0xFEFF ->
        true

      {:ok, {first, _, _, _, _, _, _, _}} when first >= 0xFF00 and first <= 0xFFFF ->
        true

      _ ->
        false
    end
  end

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

  defp private_address?({0, 0, 0, 0, 0, ipv4_marker, high, low}) when ipv4_marker in [0, 0xFFFF] do
    {a, b, c, d} = ipv4_octets(high, low)
    private_ipv4_address?({a, b, c, d})
  end

  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEFF, do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first >= 0xFF00 and first <= 0xFFFF, do: true
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
